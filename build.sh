#!/bin/bash
# Assembles and publishes a ${NAME}.bundle.zip to GitHub Releases, then
# prints the SHA256 of the file GitHub actually serves (which differs from
# the local zip because GitHub re-compresses uploads).
#
# Usage:
#   ./build.sh          — build, upload as the version in version.txt, print SHA256
#
# After running, paste the printed SHA256 into registry.json.
set -e

NAME=ChorographCodexCLIPlugin
REPO=aorgcorn/chorograph-codex-cli-plugin
BUNDLE="${NAME}.bundle"
BUILD_DIR=".build/release"

echo "Building ${NAME}..."
swift build -c release

echo "Assembling ${BUNDLE}..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"

# Plugin dylib (renamed to match CFBundleExecutable)
cp "${BUILD_DIR}/lib${NAME}.dylib" "${BUNDLE}/Contents/MacOS/${NAME}"

# SDK dylib — must live next to the plugin binary so @loader_path rpath resolves.
# dyld caches by install name, so if the host already loaded the SDK the plugin
# will reuse that image; this copy is only needed as a fallback.
cp "${BUILD_DIR}/libChorographPluginSDK.dylib" "${BUNDLE}/Contents/MacOS/"

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
VERSION=$(cat version.txt)
TAG="v${VERSION}"
ASSET="${NAME}.bundle.zip"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

echo "Publishing ${TAG} to ${REPO}..."
# Delete any existing release/tag with this name so the upload is idempotent.
gh release delete "${TAG}" --repo "${REPO}" --yes 2>/dev/null || true
git tag -d "${TAG}" 2>/dev/null || true
git push origin ":refs/tags/${TAG}" 2>/dev/null || true

git tag "${TAG}"
git push origin "${TAG}"
gh release create "${TAG}" "${ASSET}" \
    --repo "${REPO}" \
    --title "${TAG}" \
    --notes "Release ${TAG}"

# ── Hash what GitHub actually serves ─────────────────────────────────────────
# GitHub re-compresses uploaded zips, so the SHA256 of the served file differs
# from the local zip. Always fetch back and hash the live asset.
echo "Fetching published asset to compute canonical SHA256..."
VERIFIED_ZIP=$(mktemp /tmp/${NAME}-verify-XXXXXX.zip)
curl -L -s -o "${VERIFIED_ZIP}" "${DOWNLOAD_URL}"
SHA=$(shasum -a 256 "${VERIFIED_ZIP}" | awk '{print $1}')
rm -f "${VERIFIED_ZIP}"

echo ""
echo "Done: ${ASSET}"
echo "Download URL : ${DOWNLOAD_URL}"
echo "SHA256       : ${SHA}"
echo ""
echo "Paste into registry.json:"
echo "  \"version\": \"${VERSION}\","
echo "  \"downloadURL\": \"${DOWNLOAD_URL}\","
echo "  \"sha256\": \"${SHA}\""
