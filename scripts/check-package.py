#!/usr/bin/env python3
"""Verify a local bundle/archive/SBOM without printing embedded paths or content."""
import pathlib
import sys

from package_validation import validate_package


def main():
    if len(sys.argv) != 4:
        raise SystemExit('Usage: check-package.py BUNDLE ARCHIVE SBOM')
    try:
        count, digests = validate_package(*map(pathlib.Path, sys.argv[1:]))
    except ValueError:
        raise SystemExit('Package verification refused: invalid bundle, archive or SBOM.') from None
    except OSError:
        raise SystemExit('Package artifact could not be read safely.') from None
    print(f'Package verified: {count} files; SHA-256 {digests["application"]}')


if __name__ == '__main__':
    main()
