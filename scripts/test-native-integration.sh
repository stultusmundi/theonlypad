#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift.sh build
build_path=$(scripts/swift.sh build --show-bin-path)
mkdir -p .local/native-integration/module-cache
fixtures=$(mktemp -d .local/native-integration/fixtures.XXXXXX)
trap 'rm -rf "$fixtures"' EXIT
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/RecoveryCoordinator.swift \
  Tests/NativeIntegration/RecoveryHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/recovery-test
.local/native-integration/recovery-test "$fixtures/ordering"
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/EditorWindowController.swift Sources/TheOnlyPad/TextUtilitiesController.swift Sources/TheOnlyPad/FolderSearchController.swift \
  Sources/TheOnlyPad/DocumentPrinting.swift Sources/TheOnlyPad/RecoveryCoordinator.swift Sources/TheOnlyPad/NativeSyntaxHighlighter.swift Sources/TheOnlyPad/LineNumberRuler.swift Sources/TheOnlyPad/DocumentTabBar.swift Sources/TheOnlyPad/WorkspaceSidebar.swift Sources/TheOnlyPad/EncodingPanelController.swift Sources/TheOnlyPad/MacroCancellation.swift Sources/TheOnlyPad/SearchPanelController.swift Tests/NativeIntegration/NativeUIHarness.swift \
  "$build_path"/PadCore.build/*.o -o .local/native-integration/ui-test
THEONLYPAD_STATE_DIRECTORY="$fixtures/ui" .local/native-integration/ui-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/SearchPanelController.swift \
  Tests/NativeIntegration/SearchHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/search-test
.local/native-integration/search-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/LargeFileWindowController.swift \
  Tests/NativeIntegration/LargeFileViewerHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/large-viewer-test
.local/native-integration/large-viewer-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/ExternalCommandController.swift \
  Tests/NativeIntegration/ExternalCommandHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/external-command-test
.local/native-integration/external-command-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/ExtensionManagerController.swift \
  Tests/NativeIntegration/ExtensionHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/extension-test
THEONLYPAD_STATE_DIRECTORY="$fixtures/extensions" .local/native-integration/extension-test Examples/CleanupExtension/manifest.json
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/WorkspaceSidebar.swift \
  Tests/NativeIntegration/WorkspaceHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/workspace-test
.local/native-integration/workspace-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/TextUtilitiesController.swift \
  Tests/NativeIntegration/TextUtilitiesHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/text-utilities-test
.local/native-integration/text-utilities-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/FolderSearchController.swift \
  Tests/NativeIntegration/FolderSearchHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/folder-search-test
.local/native-integration/folder-search-test
native_sources=()
for source in Sources/TheOnlyPad/*.swift; do
  if [ "$source" != "Sources/TheOnlyPad/TheOnlyPadApplication.swift" ]; then native_sources+=("$source"); fi
done
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/LaunchHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/launch-test
THEONLYPAD_STATE_DIRECTORY="$fixtures/launch" .local/native-integration/launch-test
python3 - "$fixtures/crash" <<'PY'
import os
import signal
import subprocess
import sys
env = dict(os.environ, THEONLYPAD_STATE_DIRECTORY=sys.argv[1])
result = subprocess.run([".local/native-integration/ui-test", "crash"], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert result.returncode == -signal.SIGKILL, "Recovery child did not reach intentional force termination"
subprocess.run([".local/native-integration/ui-test", "restore"], env=env, check=True)
PY
