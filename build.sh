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

# Do NOT bundle the SDK dylib. dyld deduplicates loaded images by resolved
# absolute path, not install name — shipping a second copy causes Swift type
# identity checks (e.g. `as? any ChorographPlugin`) to fail across the dlopen
# boundary because two distinct images end up in the process.
#
# Instead, point the plugin binary at the same SDK the host already has loaded:
#   • @executable_path/../Frameworks  — proper .app bundle layout
#   • @executable_path                — SPM / swift run layout (.build/debug/)
install_name_tool -add_rpath "@executable_path/../Frameworks" "${BUNDLE}/Contents/MacOS/${NAME}"
install_name_tool -add_rpath "@executable_path"                "${BUNDLE}/Contents/MacOS/${NAME}"

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
# GitHub re-compresses uploaded zips, and the CDN may serve a transitional
# copy on the first request. Fetch twice and keep re-trying until two
# consecutive fetches produce the same hash — that's the stable canonical hash.
echo "Fetching published asset to compute canonical SHA256..."
VERIFIED_ZIP=$(mktemp /tmp/${NAME}-verify-XXXXXX.zip)
PREV_SHA=""
SHA=""
for i in 1 2 3 4 5; do
    sleep 3
    curl -L -s -o "${VERIFIED_ZIP}" "${DOWNLOAD_URL}"
    SHA=$(shasum -a 256 "${VERIFIED_ZIP}" | awk '{print $1}')
    if [ "${SHA}" = "${PREV_SHA}" ]; then
        break
    fi
    PREV_SHA="${SHA}"
done
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
