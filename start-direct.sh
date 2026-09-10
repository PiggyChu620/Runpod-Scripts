#!/bin/bash

# ============================================================
# Runpod + LM Studio DIRECT startup script
# Qwen3-VL-235B-A22B-Thinking-Heretic Q8_0
#
# This version does NOT copy the model to /dev/shm or /model-cache.
# It loads the persistent GGUF directly from /workspace.
# ============================================================

MODEL_ID="qwen3-vl-heretic"
CONTEXT=65536

MODEL_DIR="/workspace/.lmstudio/models/mradermacher/Qwen3-VL-235B-A22B-Thinking-heretic-GGUF"
MODEL_NAME="Qwen3-VL-235B-A22B-Thinking-heretic.Q8_0.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
DISK_PATH="$MODEL_PATH.disk"
EXPECTED_BYTES=249940106592

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
echo "  Starting Qwen3-VL DIRECT from disk"
echo "========================================"
echo

# ------------------------------------------------------------
# 1. Restore persistent LM Studio directory
# ------------------------------------------------------------

echo "[1/6] Connecting persistent LM Studio directory..."
mkdir -p /workspace/.lmstudio

if [ ! -L /root/.lmstudio ] || [ "$(readlink -f /root/.lmstudio 2>/dev/null)" != "/workspace/.lmstudio" ]; then
    rm -rf /root/.lmstudio
    ln -s /workspace/.lmstudio /root/.lmstudio
fi

export PATH="/workspace/.lmstudio/bin:$PATH"
command -v lms >/dev/null 2>&1 || fail "The 'lms' command was not found."

# ------------------------------------------------------------
# 2. Restore direct persistent model path
# ------------------------------------------------------------

echo "[2/6] Checking persistent Q8 model..."
mkdir -p "$MODEL_DIR"

# If this model has never been converted to *.disk, preserve the
# original file as the persistent master now.
if [ ! -e "$DISK_PATH" ] && [ -f "$MODEL_PATH" ] && [ ! -L "$MODEL_PATH" ]; then
    mv "$MODEL_PATH" "$DISK_PATH" || fail "Could not rename the model to its persistent .disk copy."
fi

verify_model "$DISK_PATH" || fail "Persistent model is missing, incomplete, or invalid: $DISK_PATH"

# start.sh may have left MODEL_PATH pointing to /dev/shm or /model-cache.
# Replace that symlink so this script definitely loads straight from disk.
rm -f "$MODEL_PATH"
ln -s "$DISK_PATH" "$MODEL_PATH" || fail "Could not link the direct model path."

echo "Direct source:"
echo "  $MODEL_PATH"
echo "  -> $DISK_PATH"
echo "Model size: $EXPECTED_BYTES bytes"

# ------------------------------------------------------------
# 3. Start llmster
# ------------------------------------------------------------

echo
echo "[3/6] Starting llmster..."

lms daemon up >/dev/null 2>&1 || true
sleep 2
lms daemon status || fail "llmster daemon did not start correctly."

# ------------------------------------------------------------
# 4. Enable LM Link
# ------------------------------------------------------------

echo
echo "[4/6] Enabling LM Link..."

lms link enable >/dev/null 2>&1 || true
lms link status || true

# ------------------------------------------------------------
# 5. Show GPUs
# ------------------------------------------------------------

echo
echo "[5/6] GPUs detected:"
nvidia-smi -L

# ------------------------------------------------------------
# 6. Load directly from persistent /workspace storage
# ------------------------------------------------------------

echo
echo "[6/6] Loading Qwen3-VL directly from persistent storage..."

echo "Context: $CONTEXT"
echo "GPU:     max"
echo "Source:  $DISK_PATH"
echo

echo "NOTE: This direct mode can be slow if /workspace reads at only ~200-250 MB/s."
echo "LM Studio may report a 503 'Loading model' health-check timeout before the"
echo "250 GB model has finished reading. That does not by itself prove corruption."
echo

if lms ps 2>/dev/null | grep -q "$MODEL_ID"; then
    echo "$MODEL_ID is already loaded."
else
    lms load "$MODEL_PATH" \
        --gpu max \
        --context-length "$CONTEXT" \
        --identifier "$MODEL_ID" || fail "Model load command returned an error."
fi

echo
echo "========================================"
echo "  READY!"
echo "========================================"
echo
lms ps
echo
echo "Loaded directly from persistent /workspace storage."
echo "Use it from LM Studio on Windows."
echo
