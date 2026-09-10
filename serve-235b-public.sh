#!/bin/bash
set -euo pipefail

# Standalone public llama.cpp server for:
# Qwen3-VL-235B-A22B-Thinking-Heretic Q8_0
# Intended for 2x B300 and 4 concurrent requests.
#
# IMPORTANT:
# - This does NOT use LM Link or LM Studio for serving.
# - Add HTTP port 8000 to Runpod's "Expose HTTP Ports" setting.
# - Runpod's HTTP proxy has a 100-second connection limit; use this
#   endpoint for testing/short requests. A production rental service
#   should put a proper gateway/direct-TLS endpoint in front.

PORT=8000
ALIAS="qwen3-vl-heretic"
PARALLEL=4
PER_SLOT_CONTEXT=65536
TOTAL_CONTEXT=$((PER_SLOT_CONTEXT * PARALLEL))

MODEL_DIR="/workspace/.lmstudio/models/mradermacher/Qwen3-VL-235B-A22B-Thinking-heretic-GGUF"
MODEL_NAME="Qwen3-VL-235B-A22B-Thinking-heretic.Q8_0.gguf"
MODEL_DISK="$MODEL_DIR/$MODEL_NAME.disk"
MODEL_NORMAL="$MODEL_DIR/$MODEL_NAME"
MODEL_RAM="/dev/shm/$MODEL_NAME"
MMPROJ="$MODEL_DIR/Qwen3-VL-235B-A22B-Thinking-heretic.mmproj-f16.gguf"
EXPECTED_BYTES=249940106592

LLAMA_DIR="/workspace/llama.cpp"
LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
KEY_FILE="/workspace/llama-api-keys.txt"

fail() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

file_is_complete_model() {
    local f="$1"
    [ -f "$f" ] || return 1
    [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -eq "$EXPECTED_BYTES" ] || return 1
    [ "$(head -c 4 "$f" 2>/dev/null || true)" = "GGUF" ] || return 1
}

echo "=============================================="
echo " Qwen3-VL 235B Heretic standalone API server"
echo "=============================================="
echo

# Prefer an already-staged RAM copy, otherwise use the persistent master.
if file_is_complete_model "$MODEL_RAM"; then
    MODEL="$MODEL_RAM"
    echo "Model source: RAM (/dev/shm)"
elif file_is_complete_model "$MODEL_DISK"; then
    MODEL="$MODEL_DISK"
    echo "Model source: persistent .disk copy"
elif file_is_complete_model "$MODEL_NORMAL"; then
    MODEL="$MODEL_NORMAL"
    echo "Model source: persistent normal GGUF"
else
    fail "Could not find a complete $EXPECTED_BYTES-byte Q8_0 GGUF."
fi

[ -f "$MMPROJ" ] || fail "Vision projector not found: $MMPROJ"

echo "Model : $MODEL"
echo "Vision: $MMPROJ"
echo

# Build llama.cpp once and keep it on /workspace.
if [ ! -x "$LLAMA_SERVER" ]; then
    echo "llama-server not found. Building current llama.cpp once..."

    if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1 || ! command -v c++ >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y git cmake build-essential
    fi

    if [ ! -d "$LLAMA_DIR/.git" ]; then
        rm -rf "$LLAMA_DIR"
        git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
    fi

    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=ON \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build "$LLAMA_DIR/build" --config Release -j "$(nproc)" --target llama-server
fi

[ -x "$LLAMA_SERVER" ] || fail "llama-server build did not produce $LLAMA_SERVER"

# Generate a persistent API key on first run. Never put the key in GitHub.
if [ ! -s "$KEY_FILE" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
    fi
    openssl rand -hex 32 > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
fi

API_KEY="$(head -n 1 "$KEY_FILE")"

# Helpful for multi-GPU pipeline work on CUDA.
export CUDA_SCALE_LAUNCH_QUEUES=4x

echo "GPUs:"
nvidia-smi -L
echo
echo "Parallel slots     : $PARALLEL"
echo "Context per slot   : $PER_SLOT_CONTEXT"
echo "Total context (-c) : $TOTAL_CONTEXT"
echo "Unified KV         : OFF"
echo "Flash Attention    : ON"
echo "KV cache type      : F16"
echo "API port           : $PORT"
echo

echo "API key file: $KEY_FILE"
echo "API key     : $API_KEY"
echo

if [ -n "${RUNPOD_POD_ID:-}" ]; then
    echo "Runpod HTTPS base URL:"
    echo "https://${RUNPOD_POD_ID}-${PORT}.proxy.runpod.net/v1"
    echo
fi

echo "Starting llama-server..."
echo "Loading directly from /workspace can take ~17 minutes at ~246 MB/s."
echo "Unlike LM Studio's lms load command, llama-server itself is not subject"
echo "to the LM Studio health-check timeout you hit earlier."
echo

exec "$LLAMA_SERVER" \
    --model "$MODEL" \
    --mmproj "$MMPROJ" \
    --alias "$ALIAS" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --api-key-file "$KEY_FILE" \
    --no-webui \
    --no-slots \
    --timeout 3600 \
    --jinja \
    --n-gpu-layers all \
    --split-mode layer \
    --tensor-split 1,1 \
    --flash-attn on \
    --parallel "$PARALLEL" \
    --no-kv-unified \
    --ctx-size "$TOTAL_CONTEXT" \
    --cache-type-k f16 \
    --cache-type-v f16 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --cont-batching
