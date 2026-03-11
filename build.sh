#!/bin/bash
# Assembles a ${NAME}.bundle.zip ready for the Chorograph plugin registry.
set -e

NAME=ChorographCodexCLIPlugin
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

SHA=$(shasum -a 256 "${NAME}.bundle.zip" | awk '{print $1}')
echo ""
echo "Done: ${NAME}.bundle.zip"
echo "SHA256: ${SHA}"
