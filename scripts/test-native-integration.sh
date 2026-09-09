#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift.sh build
build_path=$(scripts/swift.sh build --show-bin-path)
scripts/test-file-state-bridge.sh "$build_path"
scripts/test-disk-action-coordinator.sh "$build_path"
scripts/test-locate-coordinator.sh "$build_path"
scripts/test-file-state-owner.sh --build-path "$build_path"
scripts/test-native-monitor-lifecycle.sh "$build_path"
scripts/test-disk-status-view.sh "$build_path"
scripts/test-disk-conflict-panel.sh
mkdir -p .local/native-integration/module-cache
fixtures=$(mktemp -d .local/native-integration/fixtures.XXXXXX)
trap 'rm -rf "$fixtures"' EXIT
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/RecoveryCoordinator.swift \
  Tests/NativeIntegration/RecoveryHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/recovery-test
.local/native-integration/recovery-test "$fixtures/ordering"
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/RecoveryCoordinator.swift \
  Tests/NativeIntegration/SessionCheckpointStoreHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/checkpoint-store-test
.local/native-integration/checkpoint-store-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/RecoveryCoordinator.swift Sources/TheOnlyPad/SessionCheckpointCoordinator.swift \
  Tests/NativeIntegration/SessionCheckpointSchedulerHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/checkpoint-scheduler-test
.local/native-integration/checkpoint-scheduler-test
# Controller dependencies include process routing, intake, registry, and prepared seeds.
ui_sources=()
for source in Sources/TheOnlyPad/*.swift; do
  case "$source" in
    Sources/TheOnlyPad/AppDelegate.swift|Sources/TheOnlyPad/TheOnlyPadApplication.swift) ;;
    *) ui_sources+=("$source") ;;
  esac
done
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${ui_sources[@]}" Tests/NativeIntegration/NativeUIHarness.swift \
  "$build_path"/PadCore.build/*.o -o .local/native-integration/ui-test
THEONLYPAD_STATE_DIRECTORY="$fixtures/ui" .local/native-integration/ui-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/PreferencesController.swift \
  Tests/NativeIntegration/PreferencesFailureHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/preferences-failure-test
.local/native-integration/preferences-failure-test
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
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/MarkdownPreviewController.swift \
  Tests/NativeIntegration/MarkdownHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/markdown-test
.local/native-integration/markdown-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/ComparisonController.swift \
  Tests/NativeIntegration/ComparisonHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/comparison-test
.local/native-integration/comparison-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/BackupManagerController.swift \
  Tests/NativeIntegration/BackupHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/backup-test
.local/native-integration/backup-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/OutlineController.swift \
  Tests/NativeIntegration/OutlineHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/outline-test
.local/native-integration/outline-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  Sources/TheOnlyPad/LineNumberRuler.swift Tests/NativeIntegration/BookmarkRulerHarness.swift \
  -o .local/native-integration/bookmark-ruler-test
.local/native-integration/bookmark-ruler-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/HelpController.swift \
  Tests/NativeIntegration/HelpHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/help-test
.local/native-integration/help-test
native_sources=()
for source in Sources/TheOnlyPad/*.swift; do
  if [ "$source" != "Sources/TheOnlyPad/TheOnlyPadApplication.swift" ]; then native_sources+=("$source"); fi
done
# Test-only same-file access and comparison counters stay out of the application model.
dirty_sources=()
for source in "${native_sources[@]}"; do
  if [ "$source" != "Sources/TheOnlyPad/EditorDocument.swift" ]; then dirty_sources+=("$source"); fi
done
dirty_model=$(python3 scripts/prepare-dirty-harness.py)
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${dirty_sources[@]}" "$dirty_model" \
  Tests/NativeIntegration/DirtyDifferentialHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/dirty-differential-test
python3 - <<'PY'
import subprocess
subprocess.run([".local/native-integration/dirty-differential-test"], check=True, timeout=60)
PY
# Same-file fixtures exercise private controller callbacks without widening the app API.
routing_sources=()
for source in "${native_sources[@]}"; do
  if [ "$source" != "Sources/TheOnlyPad/EditorWindowController.swift" ]; then routing_sources+=("$source"); fi
done
cat Sources/TheOnlyPad/EditorWindowController.swift Tests/NativeIntegration/SharedPaneCommandsHarness.swift \
  > "$fixtures/SharedPaneCommandsCombined.swift"
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${routing_sources[@]}" "$fixtures/SharedPaneCommandsCombined.swift" \
  "$build_path"/PadCore.build/*.o -o .local/native-integration/shared-pane-commands-test
for mode in default close-composition late-close late-json late-encoding stale-selection stale-edit stale-detach stale-tab positive orphan-callback save-freeze find-reactivate outline-reactivate noninteractive-navigation; do
  THEONLYPAD_STATE_DIRECTORY="$fixtures/routing-$mode" .local/native-integration/shared-pane-commands-test "$mode"
done
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" Tests/NativeIntegration/VisiblePaneHarness.swift \
  "$build_path"/PadCore.build/*.o -o .local/native-integration/visible-pane-test
for mode in default cache-settings refusals noninteractive-navigation; do
  THEONLYPAD_STATE_DIRECTORY="$fixtures/visible-$mode" .local/native-integration/visible-pane-test "$mode"
done
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/LaunchHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/launch-test
THEONLYPAD_STATE_DIRECTORY="$fixtures/launch" .local/native-integration/launch-test
for capture_harness in EditorPaneHostHarness SharedHighlightHarness SharedPaneHighlightHarness SharedPaneOwnershipHarness SessionCaptureHarness SessionMetadataCaptureHarness SessionChangeHarness WindowCheckpointHarness ApplicationCheckpointHarness; do
  swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
    -I "$build_path/Modules" "${native_sources[@]}" \
    "Tests/NativeIntegration/$capture_harness.swift" "$build_path"/PadCore.build/*.o \
    -o ".local/native-integration/$capture_harness"
  ".local/native-integration/$capture_harness"
done
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/SaveFailureHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/save-failure-test
THEONLYPAD_STATE_DIRECTORY="$fixtures/save-failure" .local/native-integration/save-failure-test
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/DirtyStateHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/dirty-state-test
.local/native-integration/dirty-state-test
for harness in NativeLifetime SessionWindow SessionIntegration ScrollExtent TabAccessibility RecentFiles RecentFilesEditor; do
  swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
    -I "$build_path/Modules" "${native_sources[@]}" \
    "Tests/NativeIntegration/${harness}Harness.swift" "$build_path"/PadCore.build/*.o \
    -o ".local/native-integration/${harness}-test"
  THEONLYPAD_STATE_DIRECTORY="$fixtures/$harness" ".local/native-integration/${harness}-test"
done
swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" Sources/TheOnlyPad/SessionRestorationController.swift \
  Tests/NativeIntegration/SessionRestorationHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/session-panel-test
.local/native-integration/session-panel-test
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

swiftc -module-cache-path .local/native-integration/module-cache -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" \
  Tests/NativeIntegration/CheckpointCrashHarness.swift "$build_path"/PadCore.build/*.o \
  -o .local/native-integration/checkpoint-crash-test
python3 - "$fixtures/checkpoint-crash" <<'PYCRASH'
import pathlib
import signal
import subprocess
import sys
state = sys.argv[1]
result = subprocess.run([".local/native-integration/checkpoint-crash-test", "write", state],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=40)
assert result.returncode == -signal.SIGKILL, "Checkpoint writer did not reach intentional force termination"
assert b"ACKNOWLEDGED_CHECKPOINT" in result.stdout, "Writer did not acknowledge its checkpoint"
assert pathlib.Path(state, "Checkpoint.expected").is_file(), "Expected checkpoint marker missing"
subprocess.run([".local/native-integration/checkpoint-crash-test", "restore", state],
               check=True, timeout=40)
PYCRASH
