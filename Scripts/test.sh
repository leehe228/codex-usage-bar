#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_dev="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
if ! env DEVELOPER_DIR="$task_dev" /usr/bin/swift --version >/dev/null 2>&1; then task_dev=/Library/Developer/CommandLineTools; fi
task_sdk="${CODEX_USAGE_SDK:-}"
if [[ -z "$task_sdk" ]]; then
    if [[ "$task_dev" == /Library/Developer/CommandLineTools && -d "$task_dev/SDKs/MacOSX26.5.sdk" ]]; then task_sdk="$task_dev/SDKs/MacOSX26.5.sdk";
    else task_sdk="$(env DEVELOPER_DIR="$task_dev" /usr/bin/xcrun --sdk macosx --show-sdk-path)"; fi
fi
task_frameworks=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
if [[ "$task_dev" == /Library/Developer/CommandLineTools && -d "$task_frameworks/XCTest.framework" ]]; then
    task_support=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
    env DEVELOPER_DIR="$task_dev" /usr/bin/swift test --disable-xctest --enable-swift-testing --build-system native --sdk "$task_sdk" -Xswiftc -I -Xswiftc "$task_support" -Xlinker -L -Xlinker "$task_support" -Xlinker -rpath -Xlinker "$task_support" -Xswiftc -F -Xswiftc "$task_frameworks" -Xlinker -F -Xlinker "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks"
else
    env DEVELOPER_DIR="$task_dev" /usr/bin/swift test --disable-xctest --enable-swift-testing --build-system native --sdk "$task_sdk"
fi
