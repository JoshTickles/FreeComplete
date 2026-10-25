#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="${1:-${FREECOMPLETE_MODEL:-}}"
if [[ ! -f "$MODEL" ]]; then
    echo "Usage: $0 /path/to/model.gguf (requires native libraries from build-app.sh)" >&2
    exit 2
fi
OUTPUT="$(mktemp "${TMPDIR:-/tmp/}/freecomplete-inference.XXXXXX")"
trap 'rm -f "$OUTPUT"' EXIT
swiftc -parse-as-library -O -swift-version 5 -D DEBUG \
    -I "$ROOT/Sources/CLlama" -L "$ROOT/.build/llama/lib" \
    -lllama -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lc++ \
    -framework Metal -framework MetalKit -framework Accelerate \
    "$ROOT/Sources/FreeComplete/Inference.swift" \
    "$ROOT/Sources/FreeComplete/LlamaEngine.swift" \
    "$ROOT/Sources/FreeComplete/PredictionLogic.swift" \
    "$ROOT/Sources/FreeComplete/Trace.swift" \
    "$ROOT/Tests/InferenceLifecycle/main.swift" -o "$OUTPUT"
for scenario in stop restart cancel cancel-preload unload-loading idle; do
    FREECOMPLETE_MODEL="$MODEL" "$OUTPUT" "$scenario"
done
echo 'Native inference lifecycle checks passed (including clean process exits)'
