#!/bin/bash

# ============================================================
# Runpod + LM Studio startup script
# Qwen3-VL-235B-A22B-Thinking-Heretic Q8_0
#
# Staging strategy:
#   1. /dev/shm RAM disk, if large enough
#   2. Fast container-disk cache, if RAM disk is too small
#
# The persistent master copy stays under /workspace as *.disk.
# ============================================================

MODEL_KEY="qwen3-vl-235b-a22b-thinking-heretic"
MODEL_ID="qwen3-vl-heretic"
CONTEXT=65536

MODEL_DIR="/workspace/.lmstudio/models/mradermacher/Qwen3-VL-235B-A22B-Thinking-heretic-GGUF"
MODEL_NAME="Qwen3-VL-235B-A22B-Thinking-heretic.Q8_0.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
DISK_PATH="$MODEL_PATH.disk"
RAM_PATH="/dev/shm/$MODEL_NAME"

CACHE_DIR="/model-cache"
CACHE_PATH="$CACHE_DIR/$MODEL_NAME"

EXPECTED_BYTES=249940106592
RAM_HEADROOM=536870912
CACHE_HEADROOM=10737418240

fail() {
    echo
    echo "========================================"
    echo "ERROR: $1"
    echo "========================================"
    exit 1
}

verify_model() {
    FILE="$1"

    [ -f "$FILE" ] || return 1

    FILE_BYTES=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
    [ "$FILE_BYTES" -eq "$EXPECTED_BYTES" ] || return 1

    FILE_MAGIC=$(head -c 4 "$FILE" 2>/dev/null)
    [ "$FILE_MAGIC" = "GGUF" ] || return 1

    return 0
}

echo "========================================"
echo "  Starting Qwen3-VL on Runpod"
echo "========================================"
echo

# ------------------------------------------------------------
# 1. Restore LM Studio persistent directory
# ------------------------------------------------------------

echo "[1/9] Connecting persistent LM Studio directory..."
mkdir -p /workspace/.lmstudio

if [ ! -L /root/.lmstudio ] || [ "$(readlink -f /root/.lmstudio 2>/dev/null)" != "/workspace/.lmstudio" ]; then
    rm -rf /root/.lmstudio
    ln -s /workspace/.lmstudio /root/.lmstudio
fi

export PATH="/workspace/.lmstudio/bin:$PATH"
command -v lms >/dev/null 2>&1 || fail "The 'lms' command was not found."

# ------------------------------------------------------------
# 2. Verify persistent master model
# ------------------------------------------------------------

echo "[2/9] Checking persistent Q8 model..."
mkdir -p "$MODEL_DIR"

# First-time conversion: turn the original model into the
# persistent *.disk master. Renaming on the same volume is fast.
if [ ! -e "$DISK_PATH" ] && [ -f "$MODEL_PATH" ] && [ ! -L "$MODEL_PATH" ]; then
    echo "Moving persistent model to:"
    echo "  $DISK_PATH"
    mv "$MODEL_PATH" "$DISK_PATH" || fail "Could not rename the persistent model."
fi

verify_model "$DISK_PATH" || fail "Persistent model is missing, incomplete, or invalid: $DISK_PATH"

echo "Persistent model OK: $EXPECTED_BYTES bytes"

# ------------------------------------------------------------
# 3. Show host/container resources
# ------------------------------------------------------------

echo
echo "[3/9] Resource check..."

echo "GPUs:"
nvidia-smi -L

echo
if [ -f /sys/fs/cgroup/memory.max ]; then
    echo -n "Container memory limit: "
    cat /sys/fs/cgroup/memory.max
fi
if [ -f /sys/fs/cgroup/memory.current ]; then
    echo -n "Container memory used : "
    cat /sys/fs/cgroup/memory.current
fi

echo
printf "/dev/shm: "
df -h /dev/shm | tail -n 1

# ------------------------------------------------------------
# 4. Pick staging location
# ------------------------------------------------------------

echo
echo "[4/9] Selecting fast model staging location..."

STAGE_PATH=""
STAGE_TYPE=""

# Reuse an already-complete RAM copy when possible.
if verify_model "$RAM_PATH"; then
    STAGE_PATH="$RAM_PATH"
    STAGE_TYPE="RAM (/dev/shm)"
    echo "Complete RAM copy already exists."
else
    # Remove an incomplete/stale RAM copy so its space is reusable.
    [ -e "$RAM_PATH" ] && rm -f "$RAM_PATH"

    SHM_FREE=$(df --output=avail -B1 /dev/shm | tail -n 1 | tr -d ' ')
    RAM_REQUIRED=$((EXPECTED_BYTES + RAM_HEADROOM))

    echo "Model bytes        : $EXPECTED_BYTES"
    echo "/dev/shm free      : $SHM_FREE"
    echo "RAM-stage required : $RAM_REQUIRED"

    if [ "$SHM_FREE" -ge "$RAM_REQUIRED" ]; then
        STAGE_PATH="$RAM_PATH"
        STAGE_TYPE="RAM (/dev/shm)"

        echo
        echo "Using RAM staging."
        echo "Copying persistent model to /dev/shm..."
        echo "This one-time copy can take ~17 minutes on a ~246 MB/s volume."
        echo

        dd if="$DISK_PATH" of="$RAM_PATH" bs=64M status=progress || fail "Copy to /dev/shm failed."
        verify_model "$RAM_PATH" || fail "RAM copy failed verification."
    else
        echo
        echo "/dev/shm is too small. Falling back to container-disk cache."

        mkdir -p "$CACHE_DIR" || fail "Could not create $CACHE_DIR"

        # Reuse a valid container cache if the script is rerun in the same Pod.
        if verify_model "$CACHE_PATH"; then
            STAGE_PATH="$CACHE_PATH"
            STAGE_TYPE="container disk ($CACHE_DIR)"
            echo "Complete container-disk cache already exists."
        else
            [ -e "$CACHE_PATH" ] && rm -f "$CACHE_PATH"

            CACHE_FREE=$(df --output=avail -B1 "$CACHE_DIR" | tail -n 1 | tr -d ' ')
            CACHE_REQUIRED=$((EXPECTED_BYTES + CACHE_HEADROOM))

            echo "Container free     : $CACHE_FREE"
            echo "Cache required     : $CACHE_REQUIRED"

            if [ "$CACHE_FREE" -lt "$CACHE_REQUIRED" ]; then
                echo
                echo "The current Pod cannot stage this Q8 model."
                echo "RAM staging needs at least $RAM_REQUIRED bytes free in /dev/shm."
                echo "Container staging needs at least $CACHE_REQUIRED bytes free."
                echo
                echo "Increase Runpod Container Disk to about 320 GB, then restart the Pod."
                fail "Neither /dev/shm nor the container disk has enough space."
            fi

            STAGE_PATH="$CACHE_PATH"
            STAGE_TYPE="container disk ($CACHE_DIR)"

            echo
            echo "Using fast container-disk staging."
            echo "Copying persistent model to $CACHE_PATH..."
            echo "The persistent /workspace copy remains untouched."
            echo

            dd if="$DISK_PATH" of="$CACHE_PATH" bs=64M status=progress || fail "Copy to container cache failed."
            verify_model "$CACHE_PATH" || fail "Container-cache copy failed verification."
        fi
    fi
fi

echo
echo "Selected staging: $STAGE_TYPE"
echo "Staged model    : $STAGE_PATH"

# ------------------------------------------------------------
# 5. Point LM Studio model path at staged copy
# ------------------------------------------------------------

echo
echo "[5/9] Linking LM Studio model path to staged copy..."

rm -f "$MODEL_PATH"
ln -s "$STAGE_PATH" "$MODEL_PATH" || fail "Could not create model symlink."

LINK_TARGET=$(readlink -f "$MODEL_PATH")
[ "$LINK_TARGET" = "$STAGE_PATH" ] || fail "Model symlink verification failed."

echo "$MODEL_PATH"
echo "  -> $STAGE_PATH"

# ------------------------------------------------------------
# 6. Start llmster
# ------------------------------------------------------------

echo
echo "[6/9] Starting llmster..."

lms daemon up >/dev/null 2>&1 || true
sleep 2
lms daemon status || fail "llmster daemon did not start correctly."

# ------------------------------------------------------------
# 7. Enable LM Link
# ------------------------------------------------------------

echo
echo "[7/9] Enabling LM Link..."

lms link enable >/dev/null 2>&1 || true
lms link status || true

# ------------------------------------------------------------
# 8. Final GPU check
# ------------------------------------------------------------

echo
echo "[8/9] GPUs ready:"
nvidia-smi -L

# ------------------------------------------------------------
# 9. Load Qwen
# ------------------------------------------------------------

echo
echo "[9/9] Loading Qwen3-VL..."

if lms ps 2>/dev/null | grep -q "$MODEL_ID"; then
    echo "$MODEL_ID is already loaded."
else
    echo "Model:   $MODEL_KEY"
    echo "Context: $CONTEXT"
    echo "GPU:     max"
    echo "Source:  $STAGE_TYPE"
    echo

    lms load "$MODEL_KEY" \
        --gpu max \
        --context-length "$CONTEXT" \
        --identifier "$MODEL_ID" || fail "Model failed to load."
fi

echo
echo "========================================"
echo "  READY!"
echo "========================================"
echo
lms ps
echo
echo "Model source: $STAGE_TYPE"
echo "Use it from LM Studio on Windows."
echo