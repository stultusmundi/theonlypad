# Application search owner component

## State and scope

The internal `ApplicationSearchOwner` and `EditorDocumentSearchSource` components
are implemented. They compile in the actual application target, which now depends
on `SearchExecution`. This checkpoint does not activate them in AppDelegate,
EditorWindowController or the search panels. Editor search still uses its existing
in-process implementation.

The owner bounds window registration, reserves document and folder consumer slots,
defers text capture until admission, fences source and result callbacks, releases
result leases, and retains one shared joined shutdown. Credentials carry document,
pane, endpoint, ownership, revision and composition identity. The source adapter is
an internal closure boundary; native credential validation remains planned.

## Reproduction

On the verified ARM64 macOS host:

```sh
scripts/test-application-search-owner.sh
```

The command accepts no arguments. It freezes current PadCore, SearchExecution,
the two owner components and the original sixteen tests into a fresh ignored
package. It verifies the source inventory and invokes the checked-in owned-process
watchdog directly. Do not wrap it in another process-group watchdog. Raw synthetic
captures and source manifests remain under ignored
`.local/application-search-owner-integration/`; each invocation uses a fresh run.

## Tested

The adopted source passed all sixteen original component tests, with no failures,
unexpected failures, skips or compiler warnings. They cover bounded registration,
deferred capture, refusal and cancellation, late completion, sibling detachment,
lease navigation, approval revalidation, identity changes, preparation/veto,
synchronous reentry, joined retention and terminal uncertainty. Tests use scripted
backend/source boundaries and do not show native windows or launch a helper.

A separate fresh frozen public package passed 1,041 existing tests: 440 PadCore,
493 SearchExecution and 108 worker-runtime cases. The sixteen component tests are
separate from that total. The actual app and helper compiled and linked without
warnings. Different-author reviews authenticated retained captures, frozen source
inventories, compiler objects, link inputs, artifacts and complete owned-process
cleanup receipts for both runs.

Strict formatting of the adopted Swift files and manifest passed. The tested host
uses Swift 6.3.3 in Swift 5 language mode, ARM64 macOS 26.6.2 and SDK 26.5. The
macOS 14 deployment target is a compiler setting; macOS 14 runtime compatibility
was not tested here.

## Planned and limitations

Native source construction, sticky revision exhaustion, nonmodal search edits,
search-panel and AppDelegate lifecycle wiring, and supervised editor execution
remain separate implementation steps. Folder adaptation, hard regex cancellation,
memory accounting and RSS, physical input, accessibility and packaged desktop
acceptance are not established by this checkpoint. Distribution artifacts were
not changed, published or notarized. Earlier unsuccessful private preparation
attempts remain in ignored evidence and are not counted as passing tests.
