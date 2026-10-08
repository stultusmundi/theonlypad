#!/usr/bin/env python3
"""Generate a development CycloneDX inventory from the final packaged executables."""
import hashlib
import json
import pathlib
import sys

from package_validation import HELPER, _bundle_info, _bundle_tree, _read_regular, _require, _require_helper


def generate(bundle, output, package_path):
    package = json.loads(_read_regular(package_path).decode("utf-8"))
    _require(isinstance(package, dict), "Package dependency metadata is invalid.")
    _require(not package.get("dependencies"),
             "External dependencies added: update the SBOM inventory before packaging.")
    files, directories = _bundle_tree(bundle)
    _require_helper(files, directories)
    _require("Contents/Info.plist" in files, "Package metadata is missing.")
    info = _bundle_info(_read_regular(files["Contents/Info.plist"][0]))
    main = "Contents/MacOS/" + info["CFBundleExecutable"]
    _require(main in files and files[main][1] & 0o111,
             "Package main executable is missing or nonexecutable.")
    main_bytes = _read_regular(files[main][0])
    helper_bytes = _read_regular(files[HELPER][0])
    _require(main_bytes and helper_bytes, "Package executable is empty.")
    manifest = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": info["CFBundleName"],
                "version": info["DevelopmentVersion"],
                "bom-ref": "application",
                "licenses": [{"license": {"id": "MIT"}}],
                "hashes": [{"alg": "SHA-256", "content": hashlib.sha256(main_bytes).hexdigest()}],
                "properties": [
                    {"name": "distribution", "value": "Local development build; not notarized or published"},
                    {"name": "minimum-macos", "value": info["LSMinimumSystemVersion"]},
                    {"name": "platform-frameworks", "value": "AppKit, Foundation, CryptoKit, Darwin, UniformTypeIdentifiers; provided by macOS"},
                    {"name": "external-package-count", "value": "0"},
                ],
            }
        },
        "components": [{
            "type": "application",
            "name": "PadSearchWorker",
            "version": info["DevelopmentVersion"],
            "bom-ref": "helper:PadSearchWorker",
            "licenses": [{"license": {"id": "MIT"}}],
            "hashes": [{"alg": "SHA-256", "content": hashlib.sha256(helper_bytes).hexdigest()}],
            "properties": [{"name": "bundle-relative-path", "value": HELPER}],
        }],
        "dependencies": [
            {"ref": "application", "dependsOn": ["helper:PadSearchWorker"]},
            {"ref": "helper:PadSearchWorker", "dependsOn": []},
        ],
    }
    output.write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    if len(sys.argv) != 4:
        raise SystemExit("Usage: sbom.py BUNDLE OUTPUT PACKAGE_JSON")
    try:
        generate(*map(pathlib.Path, sys.argv[1:]))
    except (ValueError, OSError, UnicodeError):
        raise SystemExit("SBOM generation refused: invalid or unreadable package inputs.") from None
    print("Wrote development SBOM with packaged executable SHA-256 hashes.")


if __name__ == "__main__":
    main()
