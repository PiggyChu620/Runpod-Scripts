#!/bin/bash

# ============================================================
# Runpod + LM Studio startup script
# Qwen3-VL-235B-A22B-Thinking-Heretic
# ============================================================

MODEL_KEY="qwen3-vl-235b-a22b-thinking-heretic"
MODEL_ID="qwen3-vl-heretic"
CONTEXT=65536

echo "========================================"
echo "  Starting LM Studio on Runpod"
echo "========================================"
echo

# ------------------------------------------------------------
# 1. Make sure LM Studio's persistent folder exists
# ------------------------------------------------------------

mkdir -p /workspace/.lmstudio

# ------------------------------------------------------------
# 2. Recreate /root/.lmstudio -> /workspace/.lmstudio
#
# /root is temporary on Runpod.
# /workspace survives Pod stops.
# ------------------------------------------------------------

if [ ! -L /root/.lmstudio ]; then
    echo "[1/6] Reconnecting persistent LM Studio folder..."

    rm -rf /root/.lmstudio
    ln -s /workspace/.lmstudio /root/.lmstudio
else
    echo "[1/6] Persistent LM Studio folder already connected."
fi

# ------------------------------------------------------------
# 3. Add LM Studio CLI to PATH
# ------------------------------------------------------------

export PATH="/workspace/.lmstudio/bin:$PATH"

if ! command -v lms >/dev/null 2>&1; then
    echo
    echo "ERROR: lms command was not found."
    echo "LM Studio may need to be reinstalled."
    exit 1
fi

echo "[2/6] LMS command found."

# ------------------------------------------------------------
# 4. Start llmster daemon
# ------------------------------------------------------------

echo "[3/6] Starting llmster..."

lms daemon up >/dev/null 2>&1

sleep 2

lms daemon status

# ------------------------------------------------------------
# 5. Enable LM Link
# ------------------------------------------------------------

echo
echo "[4/6] Enabling LM Link..."

lms link enable >/dev/null 2>&1 || true

lms link status

# ------------------------------------------------------------
# 6. Show GPUs
# ------------------------------------------------------------

echo
echo "[5/6] GPUs detected:"

nvidia-smi -L

# ------------------------------------------------------------
# 7. Load Qwen if it isn't already loaded
# ------------------------------------------------------------

echo
echo "[6/6] Checking model..."

if lms ps 2>/dev/null | grep -q "$MODEL_ID"; then
    echo "$MODEL_ID is already loaded."
else
    echo "Loading:"
    echo "$MODEL_KEY"
    echo
    echo "Context length: $CONTEXT"
    echo "GPU offload: MAX"
    echo

    lms load "$MODEL_KEY" \
        --gpu max \
        --context-length "$CONTEXT" \
        --identifier "$MODEL_ID"

    if [ $? -ne 0 ]; then
        echo
        echo "========================================"
        echo "ERROR: Model failed to load."
        echo "========================================"
        exit 1
    fi
fi

echo
echo "========================================"
echo "  READY!"
echo "========================================"
echo
echo "Loaded models:"
lms ps
echo
echo "You can now use the model from"
echo "LM Studio on your Windows PC."
echo
