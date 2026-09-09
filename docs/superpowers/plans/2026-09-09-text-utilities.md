# Text utilities plan

Planned: strict UTF-8 Base64, RFC 3986 component percent encoding, complete JSON string literal escaping/unescaping and SHA-256, plus a native immutable-input preview panel.

1. Write known-value, malformed-input, exact Unicode byte-round-trip and input/expansion-limit tests; observe missing implementation failure.
2. Implement bounded core operations with system Foundation/CryptoKit only. Both input and output are limited to 2,000,000 UTF-8 bytes.
3. Implement native operation choice, asynchronous read-only preview, copy and explicit replacement. SHA-256 is copy-only. Prevent stale jobs from replacing or copying an output for a different operation.
4. Retain a native controller harness exercising target/action preview and replacement. Root owns the document identity/exact-text guard, undo grouping and menu wiring.

Dialect: Base64 is canonical RFC 4648 standard alphabet with padding and no whitespace. URL encoding preserves only RFC 3986 unreserved bytes; spaces become `%20`, plus signs are not form-space markers. Decoding validates percent triplets and UTF-8; unescaped Unicode and plus signs remain literal. JSON escaping emits a complete quoted JSON string; unescaping accepts exactly a JSON string value, with standard surrounding JSON whitespace allowed. SHA-256 hashes the exact UTF-8 bytes.

## Implemented

`TextUtilities.process` implements the seven operations, with canonical Base64 checks, strict decoded UTF-8 (including preservation of leading BOM content), and expansion checks before percent/JSON output grows beyond the cap. `TextUtilitiesController` captures immutable input, computes off the main thread, exposes a read-only preview, disables stale/error output actions, supports explicit replacement and copy, and makes checksums copy-only. Native window closure invalidates pending results. An optional pasteboard dependency defaults to the general pasteboard and permits isolated clipboard testing.

## Tested

On 2026-09-09, `scripts/swift.sh test --filter TextUtilitiesTests --scratch-path .build/text-utilities` built the application and passed **5 tests, 0 failures**. The first test run had observed the missing implementation; a tuple type-inference issue in the test fixture was then corrected. Coverage includes independently known Base64, percent-encoding, JSON and SHA-256 values; exact Unicode/combining/BOM/control-byte round trips; malformed padding and UTF-8; incomplete/invalid escapes; non-string JSON and lone surrogates; and input/expanded-output limits.

`Tests/NativeIntegration/TextUtilitiesHarness.swift` was compiled with the actual controller and tested PadCore objects and executed successfully. It verifies preview without automatic replacement, native Replace target/action, real Copy target/action using an isolated pasteboard, copy-only checksums, errors disabling actions, rapid operation switching discarding stale work, and traffic-light closure invalidating output. The user's clipboard was not changed. `git diff --check` passed.

## Outstanding

Root owns applying to the original selected range/document using identity and exact UTF-16 guards, native undo/macro integration, and menu/palette dispatch. The controller harness exercises real AppKit controls but does not prove packaged GUI access, accessibility navigation, or those editor integration paths. These utilities do not read/write files or invoke processes/network; Copy Output writes only to the configured pasteboard when explicitly activated.
