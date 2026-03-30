#!/bin/bash
# Builds the WASM plugin and Swift bundle, publishes both to GitHub Releases,
# then prints the SHA256 of the WASM file GitHub actually serves.
#
# Usage:
#   ./build.sh          — build WASM + bundle, upload as the version in version.txt, print SHA256
#
# After running, paste the printed values into registry.json.
set -e

NAME=ChorographCodexCLIPlugin
WASM_CRATE=chorograph-codex-cli-plugin-rust
WASM_OUT=chorograph_codex_cli_plugin_rust.wasm
REPO=aorgcorn/chorograph-codex-cli-plugin
BUNDLE="${NAME}.bundle"
BUILD_DIR=".build/release"

VERSION=$(cat version.txt)
TAG="v${VERSION}"

# ── Build WASM ─────────────────────────────────────────────────────────────────
echo "Building WASM (wasm32-unknown-unknown)..."
cargo build --release --target wasm32-unknown-unknown
WASM_SRC="target/wasm32-unknown-unknown/release/${WASM_CRATE//-/_}.wasm"
cp "${WASM_SRC}" "${WASM_OUT}"
echo "WASM built: ${WASM_OUT} ($(du -sh ${WASM_OUT} | cut -f1))"

# ── Build Swift bundle ─────────────────────────────────────────────────────────
echo "Building Swift bundle ${BUNDLE}..."
swift build -c release

echo "Assembling ${BUNDLE}..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"

cp "${BUILD_DIR}/lib${NAME}.dylib" "${BUNDLE}/Contents/MacOS/${NAME}"

cat > "${BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ChorographCodexCLIPlugin</string>
    <key>CFBundleIdentifier</key>
    <string>com.aorgcorn.chorograph.plugin.codex-cli</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
PLIST

echo "Packaging ${NAME}.bundle.zip..."
rm -f "${NAME}.bundle.zip"
zip -r "${NAME}.bundle.zip" "${BUNDLE}"
rm -rf "${BUNDLE}"

# ── Publish to GitHub Releases ────────────────────────────────────────────────
WASM_URL="https://github.com/${REPO}/releases/download/${TAG}/${WASM_OUT}"
BUNDLE_URL="https://github.com/${REPO}/releases/download/${TAG}/${NAME}.bundle.zip"

echo "Publishing ${TAG} to ${REPO}..."
# Delete any existing release/tag with this name so the upload is idempotent.
gh release delete "${TAG}" --repo "${REPO}" --yes 2>/dev/null || true
git tag -d "${TAG}" 2>/dev/null || true
git push origin ":refs/tags/${TAG}" 2>/dev/null || true

git tag "${TAG}"
git push origin "${TAG}"
gh release create "${TAG}" "${WASM_OUT}" "${NAME}.bundle.zip" \
    --repo "${REPO}" \
    --title "${TAG}" \
    --notes "Release ${TAG}"

# ── Hash what GitHub actually serves (WASM) ──────────────────────────────────
# The CDN may serve a transitional copy on the first request. Retry until two
# consecutive fetches produce the same hash — that is the stable canonical hash.
echo "Fetching published WASM to compute canonical SHA256..."
VERIFIED=$(mktemp /tmp/${NAME}-verify-XXXXXX.wasm)
PREV_SHA=""
SHA=""
for i in 1 2 3 4 5; do
    sleep 3
    curl -L -s -o "${VERIFIED}" "${WASM_URL}"
    SHA=$(shasum -a 256 "${VERIFIED}" | awk '{print $1}')
    if [ "${SHA}" = "${PREV_SHA}" ]; then
        break
    fi
    PREV_SHA="${SHA}"
done
rm -f "${VERIFIED}"

echo ""
echo "Done!"
echo "WASM URL   : ${WASM_URL}"
echo "Bundle URL : ${BUNDLE_URL}"
echo "SHA256     : ${SHA}"
echo ""
echo "Paste into registry.json:"
echo "  \"version\": \"${VERSION}\","
echo "  \"wasm_url\": \"${WASM_URL}\","
echo "  \"sha256\": \"${SHA}\""
