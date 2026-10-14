#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$(mktemp "${TMPDIR:-/tmp/}/freecomplete-prediction.XXXXXX")"
trap 'rm -f "$OUTPUT"' EXIT
swiftc "$ROOT/Sources/FreeComplete/PredictionLogic.swift" "$ROOT/Tests/PredictionLogic/main.swift" -o "$OUTPUT"
"$OUTPUT"
