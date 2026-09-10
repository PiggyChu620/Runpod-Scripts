#!/bin/bash
set -e

export PATH="/workspace/.lmstudio/bin:$PATH"

MODEL_KEY="qwen3-vl-235b-a22b-thinking-heretic"
MODEL_ID="qwen3-vl-heretic"
CONTEXT=65536
PARALLEL=2

# Remove an existing instance so the requested load settings are guaranteed to apply.
lms unload "$MODEL_ID" >/dev/null 2>&1 || true

# The lms CLI does not currently expose the Unified KV Cache toggle,
# so use LM Studio's Python SDK for this load configuration.
if ! python3 -c 'import lmstudio' >/dev/null 2>&1; then
    python3 -m pip install -q -U 'lmstudio>=1.2.0'
fi

python3 - <<PY
import lmstudio as lms

client = lms.get_default_client()

model = client.llm.load_new_instance(
    "$MODEL_KEY",
    "$MODEL_ID",
    config={
        "contextLength": $CONTEXT,
        "gpu": {
            "ratio": 1.0,
        },
        "maxParallelPredictions": $PARALLEL,
        "useUnifiedKvCache": False,
    },
)

print("Loaded:", "$MODEL_ID")
print("Unified KV Cache: OFF")
print("Max Concurrent Predictions:", $PARALLEL)
print("Context Length:", $CONTEXT)
print(model.get_load_config())
PY
