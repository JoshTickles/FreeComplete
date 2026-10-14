#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT=f2cc7282ce0042641df55e0e563b75e824e2b647
MODEL_REV=a9bf638e53783fc93778f357cc5c672eab5393b1
MODEL_SHA=3cc0e9c2b4bbffea7f3f6cfe1ffd1591f4dafe02c43f78952f1142a24172df65
LICENSE_SHA=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
CACHE="${FREECOMPLETE_BUILD_CACHE:-${HOME}/Library/Caches/FreeComplete}"
MODEL="$CACHE/model/gemma-4-E2B.i1-Q4_K_M.gguf"
MODEL_LICENSE="$CACHE/model/Apache-2.0.txt"
TOKEN_PROBS_PATCH="$ROOT/scripts/llama-raw-token-probabilities.patch"
TOKEN_PREFIX_PATCH="$ROOT/scripts/llama-token-prefix.patch"
SHARED_PREFIX_PATCH="$ROOT/scripts/llama-shared-prefix.patch"
DEST="$ROOT/dist"
# A stable identity keeps macOS Accessibility approval across rebuilds; an ad-hoc
# signature changes every build and invalidates it. Prefer an explicit identity,
# then an optional self-signed "FreeComplete Local" certificate, then ad-hoc.
LOCAL_SIGN_IDENTITY="FreeComplete Local"
if [[ -n "${FREECOMPLETE_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$FREECOMPLETE_SIGN_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -qF "\"$LOCAL_SIGN_IDENTITY\""; then
    SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
else
    SIGN_IDENTITY=-
fi

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'This build packages a macOS 14+ Apple Silicon app; run it on an arm64 Mac.' >&2
    exit 1
fi
for tool in git cmake swift codesign otool shasum plutil curl; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$CACHE/model"
PATCH_SHA="$(shasum -a 256 "$TOKEN_PREFIX_PATCH" "$TOKEN_PROBS_PATCH" "$SHARED_PREFIX_PATCH" | cut -d ' ' -f 1 | shasum -a 256 | cut -d ' ' -f 1)"
SOURCE="$CACHE/llama.cpp-$COMMIT-$PATCH_SHA"
BUILD="$CACHE/llama-build-$COMMIT-$PATCH_SHA-arm64"
fetch_verified() {
    local url="$1" destination="$2" expected="$3" part="$2.part"
    if [[ -f "$destination" && "$(shasum -a 256 "$destination" | cut -d ' ' -f 1)" == "$expected" ]]; then
        return
    fi
    curl -fL --retry 3 -C - "$url" -o "$part"
    if [[ "$(shasum -a 256 "$part" | cut -d ' ' -f 1)" != "$expected" ]]; then
        # A server may ignore Range and append a full response to a stale part.
        curl -fL --retry 3 "$url" -o "$part"
    fi
    [[ "$(shasum -a 256 "$part" | cut -d ' ' -f 1)" == "$expected" ]] || {
        echo "Downloaded file has an unexpected checksum: $destination" >&2; exit 1;
    }
    mv "$part" "$destination"
}
fetch_verified \
    "https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF/resolve/$MODEL_REV/gemma-4-E2B.i1-Q4_K_M.gguf?download=true" \
    "$MODEL" "$MODEL_SHA"
fetch_verified 'https://www.apache.org/licenses/LICENSE-2.0.txt' "$MODEL_LICENSE" "$LICENSE_SHA"

# Cache the pinned upstream checkout and build products outside the repository.
mkdir -p "$CACHE"
if [[ ! -e "$SOURCE" ]]; then
    git init -q "$SOURCE"
    git -C "$SOURCE" remote add origin https://github.com/ggml-org/llama.cpp.git
fi
[[ -d "$SOURCE/.git" ]] || { echo "Not a llama.cpp checkout: $SOURCE" >&2; exit 1; }
if ! git -C "$SOURCE" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    git -C "$SOURCE" fetch --depth 1 origin "$COMMIT"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)" != "$COMMIT" ]]; then
    [[ -z "$(git -C "$SOURCE" status --porcelain)" ]] || {
        echo "Source cache has local modifications: $SOURCE" >&2; exit 1;
    }
    git -C "$SOURCE" checkout --detach "$COMMIT"
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$COMMIT" ]] || exit 1
# Construct the expected pinned tree plus our three original runtime patches.
PATCH_INDEX="$(mktemp "$CACHE/freecomplete-patch-index.XXXXXX")"
trap 'rm -f "$PATCH_INDEX" "$PATCH_INDEX.lock"' EXIT
rm -f "$PATCH_INDEX"
GIT_INDEX_FILE="$PATCH_INDEX" git -C "$SOURCE" read-tree "$COMMIT"
for patch in "$TOKEN_PREFIX_PATCH" "$TOKEN_PROBS_PATCH" "$SHARED_PREFIX_PATCH"; do
    if ! GIT_INDEX_FILE="$PATCH_INDEX" git -C "$SOURCE" apply --cached "$patch"; then
        echo "Runtime patch does not match the pinned source: $patch" >&2
        exit 1
    fi
done
if ! git -C "$SOURCE" diff --cached --quiet ||
   [[ -n "$(git -C "$SOURCE" ls-files --others --exclude-standard)" ]]; then
    echo "Source cache has staged or untracked changes: $SOURCE" >&2
    exit 1
fi
# Compare the complete series. Later patches can modify an earlier patch's hunks,
# so testing each patch in reverse cannot identify an already-patched checkout.
if ! GIT_INDEX_FILE="$PATCH_INDEX" git -C "$SOURCE" diff --quiet; then
    if ! git -C "$SOURCE" diff --quiet; then
        echo "Source cache differs from the pinned or fully patched tree: $SOURCE" >&2
        exit 1
    fi
    for patch in "$TOKEN_PREFIX_PATCH" "$TOKEN_PROBS_PATCH" "$SHARED_PREFIX_PATCH"; do
        if ! git -C "$SOURCE" apply "$patch"; then
            echo "Could not apply runtime patch: $patch" >&2
            exit 1
        fi
    done
fi
if ! GIT_INDEX_FILE="$PATCH_INDEX" git -C "$SOURCE" diff --quiet; then
    echo "Source cache differs from the exact pinned source plus our patches: $SOURCE" >&2
    exit 1
fi
rm -f "$PATCH_INDEX" "$PATCH_INDEX.lock"

cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_SUBPROCESS=OFF
cmake --build "$BUILD" --config Release --target llama-server -j 4
HELPER="$BUILD/bin/llama-server"
[[ -x "$HELPER" ]] || { echo 'llama-server build produced no executable.' >&2; exit 1; }

# Any Homebrew/private dylib dependency would make the bundle non-portable.
otool -L "$HELPER" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p' | while IFS= read -r dependency; do
    case "$dependency" in
        /usr/lib/*|/System/Library/*) ;;
        *) echo "Non-system llama-server dependency: $dependency" >&2; exit 1 ;;
    esac
done

swift build --package-path "$ROOT" -c release --product FreeComplete
EXECUTABLE="$ROOT/.build/release/FreeComplete"
[[ -x "$EXECUTABLE" ]] || { echo 'FreeComplete build produced no executable.' >&2; exit 1; }

mkdir -p "$DEST"
STAGE="$(mktemp -d "$DEST/.FreeComplete.XXXXXX")"
OUTPUT="$DEST/FreeComplete.app"
cleanup() {
    if [[ -e "$STAGE/previous.app" && ! -e "$OUTPUT" ]]; then
        mv "$STAGE/previous.app" "$OUTPUT"
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
APP="$STAGE/FreeComplete.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses/llama.cpp"
cp "$EXECUTABLE" "$APP/Contents/MacOS/FreeComplete"
cp "$HELPER" "$APP/Contents/MacOS/llama-server"
cp "$MODEL" "$APP/Contents/Resources/model.gguf"
cp "$MODEL_LICENSE" "$APP/Contents/Resources/Licenses/Gemma-4-E2B-Apache-2.0.txt"
cp "$ROOT/Licenses/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.txt"
cp "$TOKEN_PROBS_PATCH" "$APP/Contents/Resources/Licenses/llama.cpp/FreeComplete-raw-token-probabilities.patch"
cp "$TOKEN_PREFIX_PATCH" "$APP/Contents/Resources/Licenses/llama.cpp/FreeComplete-token-prefix.patch"
cp "$SHARED_PREFIX_PATCH" "$APP/Contents/Resources/Licenses/llama.cpp/FreeComplete-shared-prefix.patch"

# Include original upstream notices for the statically linked dependencies, not only the top-level MIT license.
while IFS= read -r -d '' file; do
    relative="${file#"$SOURCE"/}"
    mkdir -p "$APP/Contents/Resources/Licenses/llama.cpp/$(dirname "$relative")"
    cp "$file" "$APP/Contents/Resources/Licenses/llama.cpp/$relative"
done < <(find "$SOURCE" -type f \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'COPYING' -o -iname 'COPYING.*' -o -iname 'NOTICE' -o -iname 'NOTICE.*' \) -not -path "$SOURCE/.git/*" -print0)

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.freecomplete</string>
    <key>CFBundleName</key><string>FreeComplete</string>
    <key>CFBundleDisplayName</key><string>FreeComplete</string>
    <key>CFBundleExecutable</key><string>FreeComplete</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>FreeComplete contributors</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# Sign nested executable first, then seal the app and its immutable model/resources.
# Local and ad-hoc signatures are for this Mac only: no hardened runtime or Apple
# timestamp. A distribution identity gets both.
SIGN_ARGS=(--timestamp=none)
if [[ "$SIGN_IDENTITY" != "-" && "$SIGN_IDENTITY" != "$LOCAL_SIGN_IDENTITY" ]]; then
    SIGN_ARGS=(--options runtime --timestamp)
fi
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/llama-server"
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP/Contents/MacOS/llama-server"
codesign --verify --strict "$APP"

# Replace only the generated destination after staging has fully succeeded.
# Keep the previous app recoverable if packaging is interrupted during replacement.
if [[ -e "$OUTPUT" ]]; then mv "$OUTPUT" "$STAGE/previous.app"; fi
if ! mv "$APP" "$OUTPUT"; then
    if [[ -e "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$OUTPUT"; fi
    exit 1
fi
echo "Packaged $OUTPUT"

# Keep an installed copy current. APFS clones share blocks with dist/, so the
# 3.4 GB bundle costs no extra space. First install: see README.
INSTALLED=/Applications/FreeComplete.app
if [[ -d "$INSTALLED" ]]; then
    rm -rf "$INSTALLED.new"
    cp -cR "$OUTPUT" "$INSTALLED.new"
    rm -rf "$INSTALLED"
    mv "$INSTALLED.new" "$INSTALLED"
    echo "Updated $INSTALLED"
fi
