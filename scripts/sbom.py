#!/usr/bin/env python3
"""Generate a development CycloneDX inventory from the actual packaged binary."""
import hashlib
import json
import pathlib
import plistlib
import sys

bundle = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
package = json.loads(pathlib.Path(sys.argv[3]).read_text())
if package.get("dependencies"):
    raise SystemExit("External dependencies added: update the SBOM inventory before packaging.")
with (bundle / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
manifest = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.6",
    "version": 1,
    "metadata": {
        "component": {
            "type": "application",
            "name": info["CFBundleName"],
            "version": info["DevelopmentVersion"],
            "licenses": [{"license": {"id": "MIT"}}],
            "hashes": [{"alg": "SHA-256", "content": hashlib.sha256(binary.read_bytes()).hexdigest()}],
            "properties": [
                {"name": "distribution", "value": "Local development build; not notarized or published"},
                {"name": "minimum-macos", "value": info["LSMinimumSystemVersion"]},
                {"name": "platform-frameworks", "value": "AppKit, Foundation, CryptoKit, Darwin, UniformTypeIdentifiers; provided by macOS"},
                {"name": "external-package-count", "value": "0"},
            ],
        }
    },
    "components": [],
}
output.write_text(json.dumps(manifest, indent=2) + "\n")
print("Wrote development SBOM with packaged binary SHA-256.")
