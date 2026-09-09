#!/usr/bin/env python3
"""Conservative tracked-source checks; not a substitute for secret scanning/review."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
paths = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
).decode().split("\0")
patterns = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    "machine home path": re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
}
failures = []
for name in sorted(set(paths)):
    if not name:
        continue
    path = root / name
    if not path.is_file():
        continue
    if path.suffix in {".p12", ".pfx", ".pem", ".key", ".mobileprovision"}:
        failures.append(f"{name}: prohibited credential container")
    data = path.read_bytes()
    for label, pattern in patterns.items():
        if pattern.search(data):
            failures.append(f"{name}: {label} pattern; inspect locally")
if failures:
    print("\n".join(failures))
    sys.exit(1)
print("Public-source pattern checks passed; no credential contents printed.")
