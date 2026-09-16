#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dev="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
if ! env DEVELOPER_DIR="$task_dev" /usr/bin/swift --version >/dev/null 2>&1; then
    task_dev=/Library/Developer/CommandLineTools
fi
task_sdk="${CODEX_USAGE_SDK:-}"
if [[ -z "$task_sdk" ]]; then
    if [[ "$task_dev" == /Library/Developer/CommandLineTools && -d "$task_dev/SDKs/MacOSX26.5.sdk" ]]; then
        task_sdk="$task_dev/SDKs/MacOSX26.5.sdk"
    else
        task_sdk="$(env DEVELOPER_DIR="$task_dev" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
    fi
fi
task_mode=release
if [[ "${1:-}" == --debug ]]; then task_mode=debug; fi
env DEVELOPER_DIR="$task_dev" /usr/bin/swift build --build-system native --sdk "$task_sdk" -c "$task_mode"
task_bin="$(env DEVELOPER_DIR="$task_dev" /usr/bin/swift build --build-system native --sdk "$task_sdk" -c "$task_mode" --show-bin-path)"
task_stage="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-bar-build.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
task_bundle="$task_stage/Codex Usage Bar.app"
task_destination="${CODEX_USAGE_APP_DIR:-$HOME/Applications}/Codex Usage Bar.app"
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
cp "$task_bin/CodexUsageBar" "$task_bundle/Contents/MacOS/CodexUsageBar"
cat > "$task_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hoeun.codex-usage-bar</string>
<key>CFBundleName</key><string>Codex Usage Bar</string>
<key>CFBundleDisplayName</key><string>Codex Usage Bar</string>
<key>CFBundleExecutable</key><string>CodexUsageBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.6</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
mkdir -p .work
 env DEVELOPER_DIR="$task_dev" /usr/bin/swift -sdk "$task_sdk" Scripts/make-icon.swift "$PWD/.work/AppIcon.iconset"
 /usr/bin/iconutil -c icns "$PWD/.work/AppIcon.iconset" -o "$task_bundle/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$task_bundle/Contents/Info.plist"
/usr/bin/xattr -cr "$task_bundle"
/usr/bin/codesign --force --sign - "$task_bundle"
/usr/bin/codesign --verify --strict "$task_bundle"
mkdir -p "$PWD/dist" "$(dirname "$task_destination")"
if [[ -e "$task_destination" ]]; then
    task_existing_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$task_existing_id" != com.hoeun.codex-usage-bar ]]; then
        printf 'Refusing to replace a different app: %s\n' "$task_destination" >&2
        exit 1
    fi
fi
/usr/bin/ditto --norsrc --noextattr "$task_bundle" "$task_destination"
/usr/bin/codesign --verify --strict "$task_destination"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$task_bundle" "$PWD/dist/Codex Usage Bar.zip"
task_link="$PWD/dist/Codex Usage Bar.app"
if [[ ! -L "$task_link" && -d "$task_link" ]]; then
    task_link_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_link/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$task_link_id" == com.hoeun.codex-usage-bar ]]; then rm -rf "$task_link"; fi
fi
if [[ ! -e "$task_link" || -L "$task_link" ]]; then ln -sfn "$task_destination" "$task_link"; fi
printf 'App: %s\n' "$task_destination"
