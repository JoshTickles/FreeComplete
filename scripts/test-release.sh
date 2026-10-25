#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp/}freecomplete-release-checks.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
swiftc "$ROOT/Sources/FreeComplete/SavingsStatistics.swift" "$ROOT/Tests/SavingsStatistics/main.swift" -o "$OUTPUT/savings"
"$OUTPUT/savings"
swiftc "$ROOT/Sources/FreeComplete/PowerPolicy.swift" "$ROOT/Tests/PowerPolicy/main.swift" -framework IOKit -o "$OUTPUT/power"
"$OUTPUT/power"
swiftc "$ROOT/Sources/FreeComplete/AccessibilityMonitor.swift" \
    "$ROOT/Sources/FreeComplete/PredictionLogic.swift" "$ROOT/Sources/FreeComplete/Trace.swift" \
    "$ROOT/Tests/AccessibilityState/main.swift" -o "$OUTPUT/accessibility"
"$OUTPUT/accessibility"
swiftc -parse-as-library "$ROOT/Sources/FreeComplete/SuggestionLifetime.swift" \
    "$ROOT/Tests/SuggestionLifetime/main.swift" -o "$OUTPUT/suggestion-lifetime"
"$OUTPUT/suggestion-lifetime"
swiftc "$ROOT/Sources/FreeComplete/ScreenContext.swift" \
    "$ROOT/Tests/ScreenContext/main.swift" -o "$OUTPUT/screen-context"
"$OUTPUT/screen-context"
