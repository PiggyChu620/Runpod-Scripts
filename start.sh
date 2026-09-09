#!/bin/bash

MODEL_KEY="qwen3-vl-235b-a22b-thinking-heretic"
MODEL_ID="qwen3-vl-heretic"
CONTEXT=65536

MODEL_DIR="/workspace/.lmstudio/models/mradermacher/Qwen3-VL-235B-A22B-Thinking-heretic-GGUF"
MODEL_NAME="Qwen3-VL-235B-A22B-Thinking-heretic.Q8_0.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
DISK_PATH="$MODEL_PATH.disk"
RAM_PATH="/dev/shm/$MODEL_NAME"
EXPECTED_BYTES=249940106592

fail() {
    echo
    echo "========================================"
    echo "ERROR: $1"
    echo "========================================"
    exit 1
}

echo "========================================"
echo "  Starting Qwen3-VL on Runpod"
echo "========================================"
echo

echo "[1/8] Connecting persistent LM Studio directory..."
mkdir -p /workspace/.lmstudio

if [ ! -L /root/.lmstudio ] || [ "$(readlink -f /root/.lmstudio 2>/dev/null)" != "/workspace/.lmstudio" ]; then
    rm -rf /root/.lmstudio
    ln -s /workspace/.lmstudio /root/.lmstudio
fi

export PATH="/workspace/.lmstudio/bin:$PATH"
command -v lms >/dev/null 2>&1 || fail "The 'lms' command was not found."

echo "[2/8] Checking persistent Q8 model..."
mkdir -p "$MODEL_DIR"

if [ ! -e "$DISK_PATH" ] && [ -f "$MODEL_PATH" ] && [ ! -L "$MODEL_PATH" ]; then
    echo "Moving persistent model to:"
    echo "  $DISK_PATH"
    mv "$MODEL_PATH" "$DISK_PATH" || fail "Could not rename the persistent model."
fi

[ -f "$DISK_PATH" ] || fail "Persistent model not found at $DISK_PATH"

DISK_BYTES=$(stat -c%s "$DISK_PATH")
[ "$DISK_BYTES" -eq "$EXPECTED_BYTES" ] || fail "Persistent model size is $DISK_BYTES bytes; expected $EXPECTED_BYTES bytes."

MAGIC=$(head -c 4 "$DISK_PATH")
[ "$MAGIC" = "GGUF" ] || fail "Persistent model does not begin with a GGUF header."

echo "Persistent model OK: $DISK_BYTES bytes"

echo
echo "[3/8] Preparing RAM copy of the 250 GB model..."

RAM_OK=0
if [ -f "$RAM_PATH" ]; then
    RAM_BYTES=$(stat -c%s "$RAM_PATH" 2>/dev/null || echo 0)
    if [ "$RAM_BYTES" -eq "$EXPECTED_BYTES" ]; then
        RAM_OK=1
        echo "Complete RAM copy already exists; skipping the slow copy."
    else
        echo "Incomplete RAM copy found; removing it."
        rm -f "$RAM_PATH"
    fi
fi

if [ "$RAM_OK" -eq 0 ]; then
    SHM_FREE=$(df --output=avail -B1 /dev/shm | tail -n 1 | tr -d ' ')
    echo "Model size : $EXPECTED_BYTES bytes"
    echo "/dev/shm free: $SHM_FREE bytes"

    [ "$SHM_FREE" -ge "$EXPECTED_BYTES" ] || fail "/dev/shm does not have enough free space for the model."

    echo
    echo "Copying model from persistent storage to RAM."
    echo "At ~246 MB/s this can take about 17 minutes."
    echo

    rm -f "$RAM_PATH"
    dd if="$DISK_PATH" of="$RAM_PATH" bs=64M status=progress || fail "Copy to /dev/shm failed."

    RAM_BYTES=$(stat -c%s "$RAM_PATH" 2>/dev/null || echo 0)
    [ "$RAM_BYTES" -eq "$EXPECTED_BYTES" ] || fail "RAM copy size is $RAM_BYTES bytes; expected $EXPECTED_BYTES bytes."
fi

echo "RAM copy verified: $EXPECTED_BYTES bytes"

echo
echo "[4/8] Linking LM Studio model path to RAM..."

rm -f "$MODEL_PATH"
ln -s "$RAM_PATH" "$MODEL_PATH" || fail "Could not create model symlink."

echo "$MODEL_PATH"
echo "  -> $RAM_PATH"

echo
echo "[5/8] Starting llmster..."

lms daemon up >/dev/null 2>&1 || true
sleep 2
lms daemon status || fail "llmster daemon did not start correctly."

echo
echo "[6/8] Enabling LM Link..."

lms link enable >/dev/null 2>&1 || true
lms link status || true

echo
echo "[7/8] GPUs detected:"
nvidia-smi -L

echo
echo "[8/8] Loading Qwen3-VL..."

if lms ps 2>/dev/null | grep -q "$MODEL_ID"; then
    echo "$MODEL_ID is already loaded."
else
    echo "Model:   $MODEL_KEY"
    echo "Context: $CONTEXT"
    echo "GPU:     max"
    echo

    lms load "$MODEL_KEY"         --gpu max         --context-length "$CONTEXT"         --identifier "$MODEL_ID" || fail "Model failed to load."
fi

echo
echo "========================================"
echo "  READY!"
echo "========================================"
echo
lms ps
echo
echo "Use the model from LM Studio on Windows."
echo
