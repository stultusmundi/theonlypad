# Readonly folder replacement preview

The locally adopted Core service computes a complete literal-replacement preview for an
explicitly selected set of at most two UTF-8 files. It returns original bytes,
proposed bytes, UTF-16 match ranges and aggregate counts. It performs no writes.
Application controls, folder-wide discovery, regex replacement, backups, Apply
and interrupted multi-file write recovery remain outstanding. C-09 remains
outstanding; these preview checks do not test a multi-file write transaction.

Default bounds are 1 MiB per source file, 1 MiB per proposed file, 4 MiB retained
source plus proposed bytes, 1,000 aggregate matches and 4,096 UTF-8 bytes for each
pattern and replacement. Callers can lower the bounds. This is a synchronous
service intended for a worker; cancellation is cooperative. These limits do not
establish physical memory peaks or hard cancellation acceptance.

The reader opens directory components and files without following symlinks. It
rejects nonregular files, multiple hard links, files without writable mode bits,
NUL paths, ambiguous URL/filesystem representations and directory-only file
spellings. Genuine directory URLs retain their trailing-slash meaning. Metadata,
file identity, ancestry and exact bytes are rechecked before completion. These
are observed consistency checks, not an immutable filesystem snapshot or
authority to overwrite files. ACL preservation and broader encoding support are
not established.

Eight original clients first failed on the declaration-only baseline. The first
productive implementation also failed because the test temporary path retained
a symlink alias and its NUL check used an escaped URL representation. Real
Foundation, descriptor and kernel-canonical diagnostics established both causes.
Only test-owned fixture preparation resolves the existing temporary base; the
production reader continues to refuse symlink traversal. A subsequent review
required lossless C-string UTF-8 validation before representation comparison.
All original behavioral oracles remain intact.

The reviewed unformatted candidate passes the original eight clients and a
separate five-client path selection. The latter uses actual percent and Unicode
filenames, distinct nested/decoy files, NUL admission controls and synthetic
symlinks. Strict formatting preserved all 13 methods and their oracles, replacing
two assignment expressions with synchronous throwing closures and removing one
redundant internal initializer. No lint rule or test was disabled.

The formatted candidate passed all 1,203 default tests in a frozen copy of the
current application. The actual app and helper built in Swift 5 mode with
warnings treated as errors. The first integrated run passed 1,202 and failed
one existing extension test because the frozen copy omitted its checked-in
example manifest. That run remains retained; including the exact tracked example
fixed the test-copy inventory without changing Source or assertions.

The exact three reviewed files are now locally adopted: the Core service and
two test files. The live checkout also passes its 13 focused tests, with the
current app and helper built with warnings treated as errors. Repository-wide
strict formatting and public-source checks pass. No dependency or asset was
added; original MIT licensing applies.

The verified filter is `FolderReplacement`. Run under the owned watchdog, using
a fresh ignored output directory when retaining receipts:

```sh
python3 scripts/run-owned-search-tests.py --timeout 240 \
  --output .local/folder-preview-verification \
  -- scripts/swift.sh test --scratch-path .build/folder-preview-verification \
  -Xswiftc -warnings-as-errors --filter FolderReplacement
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
```

Independent review accepts the 1,203-test frozen integration and the exact
three-file adoption. This record does not establish packaged desktop, physical
input, Apply, performance or complete folder-replacement acceptance.
