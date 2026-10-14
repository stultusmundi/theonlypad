# Application search coordinator component

Checkpoint: 2026-10-15, ARM64 macOS 26.6.2, Swift 6.3.3. Authored modules use Swift 5 language mode and a macOS 14 deployment target. This is component evidence; the app still uses its legacy Find route.

| State | Scope |
| --- | --- |
| Implemented | One lazy application search owner; exact quit preparation, reversible veto, retained terminal join and nested settlement classification. |
| Tested | Ten Foundation component cases, fifteen pure runner controls, current app/helper compilation and repository checks. |
| Planned | Native editor binding, AppDelegate installation and routing, actual supervised editor search. |
| Outstanding | Matched application acceptance, packaged desktop, physical input, memory and broader BUILD criteria. |

The coordinator stores its fixed application-bundle configuration without constructing a service. First Find creates the actual service/backend/owner chain. A construction reservation refuses synchronous re-entry; only a failed pre-creation attempt can retry construction. Two real owner-issued window tickets share that owner.

Quit preparation consumes existing request, result and approval rights before callbacks. The managed preparation operation must return before search terminal admission. A veto resumes only the exact reversible preparation. Once terminal admission occurs, later explicit attempts retain the original join and first parent outcome while refreshing their native preparation. Caller cancellation does not cancel the owner's join. Settlement checks the real nested fields and production resident reservation; a zero active count alone is insufficient. The Foundation operation callback proves ordering, not native checkpoint publication authority.

## Reproduce

Run from the repository root:

```sh
python3 -B -m unittest discover -s Tests/NativeApplicationSearchesIntegration -p test_native_application_searches_runner.py
scripts/test-native-application-searches.sh
```

The fixed native command accepts no arguments. It freezes current public Core/Search sources, four coordinator component sources and one test file. It performs one cold ten-case run and owns the checked-in process watchdog directly; never wrap it in another process-group watchdog. There are no test access tails, historical source-hash gates, caller-selected filters or prebuilt artifacts. `Package.swift.expected` is pure-test data and is not a runtime input.

The final run passed ten tests with zero failures or skips. Its actual graph contains 100 copied inputs, one generated 548-byte manifest and two separate provenance copies; 98 objects, five modules, 135 bound artifacts and four XCTest bundle leaves. Original/frozen bytes and identities, exact membership, compiler file lists/output maps, the sole complete object link union, artifacts, case census and complete watchdog receipt were checked. The generated XCTest entry has no explicit Swift-language flag; it is qualified separately from authored modules.

The unchanged panel/session/owner command separately passed 45 tests. Its 95 shared production originals match the coordinator run. These are separate builds, not a combined 55-case acceptance run.

Current app and helper compilation also passed with warnings treated as errors: 194 production sources across five actual built modules. Both executable link unions were checked. Planned unbuilt test commands in SwiftPM's description were excluded from this evidence. The public pure fifteen controls, full strict source formatting, public-source checks and whitespace checks pass.

## Evidence and limits

Raw synthetic records stay ignored under `.local/native-application-searches-integration/`. The final run is `run.93DF0561-2614-442D-9EA5-FB6B8D4C7109`; Root observation SHA256 is `9e890bf4556719a80cb4f3251302e337a3cd1af8e33e45a0ce0c62e82cb32014`. Final coordinator Swift source is 12,296 bytes, SHA256 `a8dc778c404230c38a5447f36bcbbc9c70cf67da2bd2fd475df6f6bb3eb75426`; formatted tests are 37,239 bytes. Earlier genuine behavioral RED and compiler setup failures remain retained in their original records.

The injected backend isolates ownership, ordering and settlement behavior. These checks do not launch a helper, execute an adversarial regular expression, publish an actual native checkpoint, activate AppDelegate search, show windows or establish process memory bounds. The fixed bundle constructor compiles but the component tests do not exercise production helper construction. Distribution artifacts and prior packaged acceptance are unchanged. No remote push, merge or release was performed.
