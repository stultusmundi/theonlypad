#!/bin/bash
# Standalone visible adapter stress benchmark; never part of the native acceptance suite.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=smoke
case "$#:${1:-}" in
  0:) ;;
  1:--full) mode=full ;;
  1:--help|1:-h) echo "Usage: scripts/benchmark-panes.sh [--full]"; exit 0 ;;
  *) echo "Usage: scripts/benchmark-panes.sh [--full]" >&2; exit 2 ;;
esac
umask 077
base="$PWD/.local/pane-benchmarks"
mkdir -p "$base"
run_directory=$(mktemp -d "$base/run.XXXXXX")
mkdir -p "$run_directory/native" "$run_directory/module-cache"
# Run only with exclusive build/GUI ownership. The children activate their synthetic window.
cp Sources/TheOnlyPad/*.swift "$run_directory/native/"
cp Tests/NativeIntegration/SharedPanePerformanceHarness.swift "$run_directory/SharedPanePerformanceHarness.swift"
git rev-parse HEAD > "$run_directory/source-commit.txt"
shasum -a 256 "$run_directory"/native/*.swift "$run_directory/SharedPanePerformanceHarness.swift" > "$run_directory/source-sha256.txt"
scripts/swift.sh build -c release --scratch-path "$base/build"
build_path=$(scripts/swift.sh build -c release --scratch-path "$base/build" --show-bin-path)
pane_package_name=$(python3 - "$build_path/description.json" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        description = json.load(stream)
except (OSError, ValueError):
    sys.exit("Cannot read the matching SwiftPM build description.")
commands = description.get("swiftCommands") if isinstance(description, dict) else None
if not isinstance(commands, dict):
    sys.exit("The matching build description has no Swift commands.")
package_names = []
for module in ("PadCore", "SearchExecution", "TheOnlyPad"):
    matches = [
        command for command in commands.values()
        if isinstance(command, dict) and command.get("moduleName") == module
    ]
    if len(matches) != 1:
        sys.exit("Expected one matching Swift command for " + module + ".")
    arguments = matches[0].get("otherArguments")
    if not isinstance(arguments, list) or not all(isinstance(value, str) for value in arguments):
        sys.exit("Invalid Swift arguments for " + module + ".")
    indexes = [index for index, value in enumerate(arguments) if value == "-package-name"]
    if len(indexes) != 1 or indexes[0] + 1 >= len(arguments):
        sys.exit("Expected one package identity for " + module + ".")
    value = arguments[indexes[0] + 1]
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,255}", value) is None:
        sys.exit("Unsupported package identity in the matching build description.")
    package_names.append(value)
if len(set(package_names)) != 1:
    sys.exit("The matching Swift modules disagree on package identity.")
print(package_names[0])
PY
)
swift --version > "$run_directory/swift-version.txt"
native_sources=()
for source in "$run_directory"/native/*.swift; do
  [[ "$source" == */TheOnlyPadApplication.swift ]] || native_sources+=("$source")
done
swiftc -O -swift-version 5 -package-name "$pane_package_name" -module-cache-path "$run_directory/module-cache" -parse-as-library \
  -I "$build_path/Modules" "${native_sources[@]}" "$run_directory/SharedPanePerformanceHarness.swift" \
  "$build_path"/PadCore.build/*.o "$build_path"/SearchExecution.build/*.o -o "$run_directory/pane-performance"
python3 scripts/benchmark-panes.py "$run_directory" --mode "$mode"
