#!/bin/bash
set -euo pipefail
umask 077
repo=$1
build_path=$2
root=$(cd "$(dirname "$0")" && pwd)
cd "$repo"
mkdir -p "$root/builds"
build_dir=$(mktemp -d "$root/builds/compile.XXXXXXXX")
exec > >(tee "$build_dir/output.log") 2>&1
trap 'code=$?; echo "$code" > "$build_dir/exit-code"' EXIT
# Public wrapper performed a real debug build first. Never infer build success from show-bin-path.
python3 - "$build_path" "$build_dir" <<'PY'
import pathlib,sys,json,hashlib
build=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2])
objects=sorted((build/'PadCore.build').glob('*.o'))
module=list((build/'Modules').glob('PadCore.*'))
assert objects and any(p.name=='PadCore.swiftmodule' for p in module), 'Debug PadCore objects/module missing'
files=[p for p in objects+module if p.is_file()]
(out/'linked-padcore-hashes.json').write_text(json.dumps({str(p.relative_to(build)):hashlib.sha256(p.read_bytes()).hexdigest()for p in files},indent=2)+'\n')
(out/'configuration.json').write_text(json.dumps({'PadCore':'debug','nativeProbe':'swiftc -O','target':'arm64-apple-macosx14.0','claim':'Mixed debug-core/optimized-native diagnostic configuration; not release-app acceptance'})+'\n')
PY
swiftc --version > "$build_dir/swift-version.txt"
swiftc -O -target arm64-apple-macosx14.0 -module-cache-path "$root/module-cache" -parse-as-library \
 -I "$build_path/Modules" "$root/Sources/"*.swift "$root/CheckpointTrace.swift" \
 "$root/CheckpointEditProbe.swift" "$build_path"/PadCore.build/*.o -o "$root/probe"
shasum -a 256 "$root/probe" > "$build_dir/probe-sha256.txt"
