# Application language catalog startup and quit

## Implemented

AppDelegate retains one actual catalog owner and its latest state. Normal
application startup requests its first read before session restoration. Constructing
the delegate or quitting before startup does not create or read the catalog.
Failures preserve the last confirmed publication; state and failure identity are
recorded before presenting an error so callback-created successor work survives.

The existing termination attempt now reserves the actual catalog before search
preparation. Busy or unresolved catalog work vetoes quit without canceling reads,
acknowledging uncertain writes, retrying or discarding them. A native/search veto
releases only that attempt's catalog reservation after its existing rollback.
Successful catalog writes remain confirmed when a later native veto occurs.

All reversible veto and cancellation gates precede catalog invalidation and the
permanent external-command drain. The actual native checkpoint receipt is retained
before later validation so a refusal can resume the prepared document owner.
After the irreversible commit, cancellation does not cause a second reply or
attempt to reopen retired services. Error/reply callback successors keep their
own attempt and reservation.

## Tested

Development commit `be6ec6f` is pushed and read back exactly. The fixed public
command passes its original four routing tests and ten catalog
startup/quit tests against current working sources:

```sh
scripts/test-application-language-catalog.sh
```

Five direct owned-watchdog stages finish naturally with zero exit: toolchain,
build, binary path, original4 and new10. Independent actual review verifies204
original inputs,198 derived files, five explicit access tails, five compiler
modules,190 objects,227 artifacts, four bundle leaves and31 adopted command/
receipt/capture/result facts. All five synthetic State directories are empty.
The current Locate correction is included; historical private UI prefixes were
not copied over the current controller. Do not wrap the command in another
session-owning watchdog.

The new tests exercise real owner load/failure/reentrant reporting, quit before
startup, busy and unresolved refusal, native/search veto, successful joined
invalidation, postcommit cancellation and false-reply successor isolation.
Actual synthetic store failures, confirmed catalog readback and native paired
checkpoint paths are exercised. Presentation/search responses are injected; no
windows, real sheets or supervised search helper are launched.

The runner's ten Python contracts pass on the raw candidate and separately on
the formatted derivative. The first180-second run completed six methods and
timed out in the seventh; it remains incomplete, with the final three unentered.
The unchanged raw retake and formatted retake pass under upfront600-second
budgets. These are synthetic filesystem/graph controls, not application latency
or performance evidence.

Formatting moves exactly two additional imports into the combined native test
header. The unmodified51,229-byte original routing file remains a provenance
input. A strict two-anchor projection produces the51,268-byte header/prefix; its
exact inverse restores every original byte. All14 method names and497 XCTest
calls remain. Corruption, stage, source, receipt and final-custody checks stay
active. The shared helper, watchdog, original app4 and real-helper3 tests remain
unchanged.

A separate current-source warnings-as-errors app/helper build and default suite
passes1,203 tests with zero failures. NativeIntegration Python discovery passes135
contracts separately. All567 pre-run source/test/support facts still match at independent
post-run inspection; complete natural zero-exit owned receipts and captures remain
local. These counts overlap other commands and must not be added together.

The separate same-source actual-helper command also passes its three fixed
regressions in fresh processes (Find/replacement/undo/joined quit, malformed
regex retry and stale approval after edit/undo). This retake covers the unchanged
helper cases with current AppDelegate; it does not show windows or establish
broad containment, memory or packaged Bundle.main acceptance.

A matching local package passes ad-hoc signing and standalone archive/SBOM
validation. The selected desktop baseline stops during UI automation setup
(xcodebuild65) before any test method; it provides no application pass or fail.

## Outstanding

This owner integration does not activate the language manager, picker, syntax
propagation or per-document language policy. Manager draft consent and recovery
UI need their own integration. Packaged startup/quit, visible sheets, physical
input, accessibility and broader performance acceptance remain outstanding.

Raw synthetic evidence stays ignored under
`.local/application-language-catalog-integration/`. Existing standalone
[read](native-language-catalog-loading.md) and
[mutation](native-language-catalog-mutation.md) results remain separate scopes.
