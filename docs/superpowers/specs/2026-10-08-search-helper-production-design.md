# Fixed search helper and nested packaging design

Status: independently reviewed; implementation and actual verification pending. Base: reviewed lifetime checkpoint `e076afa`.

Architecture: one fixed SwiftPM helper binds the existing worker Program, Darwin
channel, strict accumulator and checked lifetime starter. Package its release
bytes at the existing resolver path, with helper-first signing and complete
archive/SBOM validation before local promotion. Parent/editor routing is separate.

macOS14 deployment target, Swift6 tools in Swift5 mode, original MIT code and
system Foundation/Darwin only. Root exclusively owns serial compiler, actual
child, packaging and GUI execution. BUILD authorizes routine design, tests and
local commits; no remote merge, push, release or security-setting change.

## Source findings and alternatives

The public manifest currently exposes PadCore and TheOnlyPad; SearchExecution and PadSearchWorkerRuntime are ordinary internal targets, and no production helper executable exists. The runtime target already depends on both PadCore and SearchExecution. Same-package access permits the new executable to use their package APIs without broadening them to public or adding unused library products.

SearchWorkerProgram already fixes bootstrap parsing, channel-before-lifetime ordering, startup-error70, the Foundation engine and exit mapping. Its strict accumulator and checked lifetime starter now exist. The FD channel explicitly needs its third `system:` argument and borrows descriptors; there is no implicit Darwin convenience initializer. The resolver already selects `Contents/Helpers/PadSearchWorker`, and its launch validation checks the final regular/executable entry without certifying ancestor trust or signatures.

The current package script builds/copies/strips only the app. SBOM `components` is empty and only the main executable is hashed. check-package compares every file against ZIP bytes, but follows filesystem links through `is_file` and does not require any helper. Promotion's second validation checks only Info.plist/main executable and the main SBOM hash. Therefore copying a helper alone would leave missing-helper and substituted-helper gaps in promotion.

The preserved private pilot demonstrates actual Program/channel/Foundation-engine/parent-driver composition, but imports experimental allocation/telemetry targets and starts Foundation Thread through a semaphore. It is historical evidence and a reference for interfaces, not production entry source to adopt. The current checked starter and concrete accumulator replace those experimental bindings. The private allocation/source-fit campaign is not a prerequisite for this slice and supplies no production memory claim.

| Approach | Decision |
| --- | --- |
| New fixed SwiftPM PadSearchWorker executable using existing package targets | Recommend: one small auditable entry, existing protocol and resolver path, no new dispatch/composition seam. |
| App executable with a helper mode or self-relaunch | Reject here: mixes AppKit startup with worker policy, expands app argument handling and changes the existing resolver contract. |
| Adopt private pilot package and its helper wholesale | Reject: adds telemetry/candidate dependencies, arbitrary private paths and obsolete watcher startup to a production product. |

## Fixed executable contract

Add product `.executable(name: "PadSearchWorker", targets: ["PadSearchWorker"])` and executable target `PadSearchWorker` with direct dependencies `PadSearchWorkerRuntime` and `SearchExecution`. Retain TheOnlyPad's existing dependency on PadCore; do not activate parent routing or add a UI dependency to the helper. Foundation/CryptoKit/Darwin remain transitive system dependencies of the existing core modules.

Create only `Sources/PadSearchWorker/PadSearchWorkerMain.swift` for the entry. The intended complete composition is:

```swift
import Darwin
import PadSearchWorkerRuntime
import SearchExecution

@main enum PadSearchWorkerMain {
  static func main() {
    let code = SearchWorkerProgram.run(
      arguments: CommandLine.arguments, inputFD: 0, outputFD: 1, controlFD: 3,
      makeChannel: {
        try SearchWorkerFDChannel(inputFD: $0, outputFD: $1, system: .darwin)
      },
      makeAccumulator: { try SearchWorkerUTF8Accumulator(declaredUTF16: $0) },
      startParentLifetime: { try SearchParentLifetime.start(controlFD: $0) })
    Darwin._exit(code)
  }
}
```

This is proposed text, not an executed entry or a source file created by this task. It adds no environment-selected implementation, fixture mode, logging, alternate engine, limit override or file access. stdout contains protocol bytes exclusively; the entry prints nothing. stderr stays diagnostic-only and is `/dev/null` under the current launcher. Parse the actual three-value argv (`argv0`, `--generation`, nonzero canonical UUID), including the existing accepted UUID case equivalence. Keep parser rejection64, protocol failure65, startup/internal/input-sink70, channel/input/output74 and clean EOF0. SearchError results remain protocol terminals and permit a subsequent request rather than terminating the helper.

Use `_exit` after Program returns so startup failure cannot leave a newly created watcher hosting a longer-lived process; no Foundation exit handlers are required. The lifetime body also uses the existing `_exit` path. The Program's request cleanup executes before its return; `_exit` is not a claim of physical allocator reclamation or secure erasure.

The trusted launcher already duplicates the request reader to0, response writer to1, null stderr to2 and blocking lifetime reader to3, then closes ancillary child descriptors. It supplies `[path, "--generation", generation]` and `LANG=C/LC_ALL=C`; production additional arguments remain empty. The worker borrows0/1/3 and never closes/duplicates them, changes global signals or adds a reaper. It installs per-output-FD no-SIGPIPE through the existing channel. The parent retains lifetime-writer authority and owns exact PID/generation cleanup. Direct invocation with arbitrary descriptor semantics is outside that verified-launch contract; startup thread creation does not itself prove fd3 is a valid blocking pipe or that the first read already ran.

## Nested artifact contract

Build both release products from the same adopted public source/package/toolchain invocation, with the ordinary existing cache paths. Independently retain input inventory, complete compiler/watchdog receipts and built/copied artifact hashes; do not substitute a private pilot or stale scratch helper.

The bundle contains exactly one regular executable helper at `Contents/Helpers/PadSearchWorker`. No helper app bundle, alternate helper name, resources, symlink or path override is needed. Create Helpers with normal bundle directory permissions, copy the release binary, set its executable mode, and run `/usr/bin/strip -S` on both distributable executable copies before any signing. Do not mutate the original build outputs. Missing or nonregular/nonexecutable product prevents packaging and promotion.

For `--ad-hoc-sign`, sign the helper first, then the enclosing app. Verify the helper and app explicitly with strict codesign verification; signing with `--deep` is unnecessary. Keep the existing unsigned development option honest. Do not infer developer identity, hardened-runtime/notarization, macOS14 execution or redistribution signing acceptance from ad-hoc signing. Any helper-content mutation after signing must fail signature and artifact-byte controls; never repair the package by signing unreviewed replacement bytes.

Generate the ZIP and SBOM only after final stripping/signing. Keep current ditto no-resource-fork/no-extended-attribute behavior and transactional three-artifact promotion/rollback. The resulting archive, app and SBOM still form one promotion set.

## SBOM and independent package validation

Retain the main application's existing metadata/hash/license/minimum-OS properties. Add one helper application component named `PadSearchWorker`, versioned with the application, MIT-licensed, with a stable component reference, its fixed bundle-relative path property and SHA256 of its final packaged bytes. Add root/helper component references and a dependency relation if using CycloneDX dependencies. This describes one bundled application component, not an external Swift package. Preserve the existing refusal when external package dependencies appear without an updated inventory.

Use one importable pure validation function shared by check-package and promotion, proposed `scripts/package_validation.py`; check-package keeps its CLI through a main guard. The function performs the current machine-path scan, safe/unique ZIP inventory, every-file ZIP byte comparison and main hash validation, then enforces the new helper contract. Both callers must independently run it before promotion, preventing a helper-only edit between the first check and staging validation from escaping.

For this dependency-free bundle, reject symlinks and special files anywhere in the validated tree, including the helper and its Helpers ancestor. Check with lstat semantics before reading. Require the fixed helper to be regular, nonempty and executable, and require Helpers membership to be exactly that helper. Reject absent/duplicate/misnamed helper SBOM components, wrong relative path/hash, unsupported external dependency metadata, and mismatch between archived helper bytes and final bundle bytes. Require S_IFREG and executable mode in the archived helper entry. Reject symlink and special file types throughout the archive; ordinary directory entries must carry directory type and names. Synthetic ZIP fixtures explicitly set regular/directory modes. Add external_attr-only negative mutations with every payload and digest unchanged. Existing safety requirements for unsafe/duplicate ZIP names and machine-path markers remain mandatory. These checks are packaging trust checks, not a claim that the runtime resolver authenticates an immutable signed ancestor tree.

Keep all existing promotion rollback assertions. Extend their synthetic valid-bundle fixture with a literal helper file, executable mode, helper SBOM component and ZIP entry so it satisfies the new format; do not remove the original main-hash/archive refusal assertions. Test the shared validator with actual synthetic files/archives, not source-string inspection.

Required negative cases: missing helper; symlink helper/Helpers ancestor; nonregular or nonexecutable helper; unexpected Helpers member; missing/duplicate helper component; wrong helper hash/path; changed helper with an independently updated bundle hash but stale ZIP bytes; omitted/replaced ZIP helper; missing ZIP execute mode; machine-path marker inside helper; stale helper bytes after initial package check rejected by promotion's independent validation. Retain the existing app-hash, CRC, unsafe-name, whole inventory and rollback cases. Codesign mutation checks are Root-owned native packaging checks and are separate from pure synthetic tests.

## Genuine small real-protocol acceptance

Use the actual new built product, and then the exact final nested stripped/signed copy selected through the actual resolver. Freeze all three production source targets, the exact entry/manifest, test sources/runner and artifact identities. A new narrowly scoped `Tests/SearchWorkerIntegration/` runner may reuse the accepted direct watchdog/manifest validation conventions; it must not run under another session-owning watchdog or reuse mutable build outputs after a later test build. Add positive selector and exact inventory pure controls before changing a coordinator mapping. A fresh reviewed generated package/target recipe must actually include the helper target and runtime target; today's lifecycle harness omits both, so merely selecting a new test name is insufficient.

The primary integration tests use the actual launcher, lifecycle, parent driver/writer/response codec, new helper Program/channel/accumulator, Foundation engine and sole reaper. Parent response collection may reuse the ordinary test collectors, but no experimental allocation candidate, echo substitute or injected worker engine reaches the executed product. Use small synthetic strings and independent literal expected values:

1. `x😀e\u{301}😀`, literal find😀 -> UTF16 ranges `(1,2)` and `(5,2)`.
2. `é猫 😀 é猫`, regex `(é)(猫)` replacement `$2:$1` -> ranges `(0,2)` and `(6,2)`, exact `猫:é 😀 猫:é`.
3. No-match replacement preserves literal initial/interior FEFF, NUL, combining units, supplementary units and mixed endings; compare explicit UTF16 units, not normalization-equivalent String equality alone.
4. One generation completes a malformed-pattern terminal `invalidPattern`, then the next increasing ordinal completes a healthy exact find; verify every request/terminal identity and no child replacement.
5. Empty request yields exact empty replacement and terminal. A transparent test-only forwarder splits the actual production connection writes into small pieces; the production parent writer and worker reader/decoder remain unchanged. Require multiple actual forwarded writes and exact `A💡B` for replacement in `A😀B`. Pipes can coalesce writes: this does not claim separate kernel reads or separate decoder inputChunk calls. Existing component cross-inputChunk tests remain separate.

Require real generation/PID binding before outcome credit, complete source/artifact snapshots before and after each execution, exact accepted terminals/ranges/text, owned signal records, one consuming reap, channel closure, no remaining child and actual parent/session scope settlement. Use the existing joined shutdown contract, or a generation-qualified real sessionReleased boundary for a retained legacy shutdown command; immediate pending snapshots are not completion. Do not infer wait status from a successful kill call, or replace an observed exit0 with signal9. Use shutdownJoined(after: latest consumed handle), requiring admitted ownership, acknowledged lane stop, stopped child/closed channels, settled parent lane and zero retained lanes. The current lifecycle requests SIGKILL during shutdown, so permit only literal observed consuming exits .exited(0) or .signaled(SIGKILL), correlated to the exact owned generation/PID and actual signal records. Protocol success is separate from shutdown classification. A read-only SearchChildSystem forwarder delegates all launch/signal/poll calls to the real launcher; it adds no wait or signal authority. Preserve all stricter historical campaign failures and the first child receipt; an initially pending receipt does not become success merely after a later snapshot.

Bad argv can be exercised as a separate direct owned helper invocation: exit64 and no stdout. Malformed/truncated wire continues to have the existing component tests; adding an actual protocol-refusal exit65 test requires a finite owned-pipe harness that keeps lifetime authority open until the exact consuming reap. Closing fd3 while waiting for protocol EOF would race the watcher's exit0; do not claim a65 observation from that schedule or bypass the reaper through competing waits. This distinction is an identified harness requirement, not a reason to delay the five complete real search cases.

Hard-regex interruption, sustained large-input/output/reuse memory measurements, parent default construction and editor routing are separate acceptance slices. No private source-fit packet, partial traversal or allocation campaign is used to certify this product.

