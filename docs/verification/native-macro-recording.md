# Native macro recording — 2026-10-12

The current working tree adopts the reviewed ten-file native macro/transfer
implementation and two Foundation transfer fixture updates. The seven-file
public test harness makes the accepted native recording slice reproducible.
Original code is MIT-licensed; no
external dependency or asset is added.

The recorder checks the current recording interval and ownership at callback
boundaries. Exact UTF-16 payload matching and a combined 64-entry admission bound
protect the supported native decision routes. Recorded commands follow committed
text changes. Unrecorded changes make the current interval incomplete; a
persistent accessible status row explains why Save is unavailable while
preserving the recorded prefix for Discard. These are tested native routes, not
universal AppKit callback or composition guarantees.

The public runner passes **19 unique hidden native tests with zero failures**:

| Selected class | Tests |
| --- | ---: |
| NativeMacroChronologyTests | 7 |
| NativeMacroApprovedViewReceiptTests | 6 |
| NativeMacroApprovedViewCapacityTests | 2 |
| NativeMacroApprovedViewPayloadTests | 2 |
| NativeMacroControlledExplicitCapacityTests | 1 |
| NativeMacroStrictExplicitCapacityTests | 1 |

The earlier 17-case selection passed before the wider explicit-entry controls
reproduced 25 ordinary failures. The reviewed correction passes the unchanged
19 cases. This history preserves the genuine failing baseline; it does not
count prerequisite compiler failures or Swift/XCTest aborts as behavioral RED.

The shared coordinator's pure suite passes **50 tests**. Its four new controls
first failed against the original coordinator; the original 46 remain intact.
The macro suite freezes the real Core, SearchExecution and native graph, copies
three accepted clients and appends five marked test-only access payloads to their
declaring files. Those payloads include controlled setters, forwarding and
teardown as well as reads. They are not production APIs or independent proof of
native lifetime cleanup. Formatting and identifier changes preserve all literal
oracles, assertion order and diagnostic enum raw values. No temporary product
trace or dirty-getter instrumentation is included.

```sh
python3 -B -m unittest discover -s Tests/NativeIntegration -p test_native_regressions.py
scripts/test-native-macro.sh
```

The native coordinator owns its direct watchdog stages. **Do not wrap it in
another session-owning watchdog.** It uses isolated synthetic state, Swift 5
mode, a macOS 14 deployment target and warnings as errors. The local executed
host was ARM64 macOS 26.6.2 with Swift 6.3.3; execution on macOS 14 is unverified.
Sources, generated transforms, objects, module companions, link inputs, actual
test binary and complete wait/capture receipts received independent review.

Separate current-source evidence includes the unrelated-recording close
conjunction (six cases), original projection (20) and native transfer (12), plus
seven transfer controls and individually selected move/history and post-atomic
retry controls. These overlap earlier tests and are not added to the 19 count.
The retry control reaches refusal after actual storage completion, then joins
the same request with one atomic commit. Foundation process/publisher coverage
is separate from native ownership and desktop acceptance.

The finalized public application snapshot passes **1,159 default SwiftPM tests**
and builds the app/helper without warnings. It includes the adopted native
sources and Core session version 3. NativeIntegration clients are outside the
default SwiftPM targets, so native19 and default1159 are separate results.
The full snapshot and subsequent incremental build have verified frozen inputs,
compiled/link products and complete direct-watchdog receipts. Reproduction is
recorded in [session codec verification](custom-language-session-codec.md).

The runner never shows windows or posts input. Visible recording/Save/Discard,
physical typing and IME, VoiceOver, broader managed lifecycle, macro shortcut
binding and packaged desktop acceptance remain outstanding. No package, release,
performance or full G-01 acceptance follows from this checkpoint. Raw synthetic
evidence stays ignored.
