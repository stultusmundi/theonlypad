# Continuation checkpoint

TheOnlyPad is incomplete. Continue the full BUILD_PROMPT autonomously. Local work and commits are authorized; remote pushes, merges, releases, credentials and security changes are not.

## Current state and next action

Branch `build/native-editor`. Managed AppDelegate activation is not implemented. Current legacy application behavior remains selected while native routing is integrated. Recent local commits: `11c7b05` history provenance (49 tests); `17134b8` close model/repair context (106 native checks, 20 process tests); `aa0a9af` process intake (16 tests); `346bb1c` managed publisher (18 tests); `3051c37` prepared native seed updates (122 factory checks); `2634078` session seed propagation (17 tests). All are local only.

Fresh frozen full-app verification at `.local/native-ownership-integrated` built in 8.77 seconds and passed 404 core tests in 15.788 seconds. Source provenance is retained there: base `d7d3d2a` plus close model/context overlays. This excludes later history, seed and native controller work. The verified core build for hidden harnesses is `.build/native-ownership-integrated/arm64-apple-macosx/debug`.

Exact next actions:

1. Latest commits: `27b905c` async panel completion (10 hidden checks); `5f40a08` native close adapters (21 controller tests); `c3ed042` concrete native intake adapter (six tests); `76d20d1` process-owned detached monitor store (23 native checks). Earlier `cbf718c` admission hooks and `51ce7d3` bridge reattachment remain verified. AppDelegate is still legacy.
2. Fresh frozen `.local/native-close-integrated` base `cbf718c` plus exact reviewed overlays built the complete app in 8.83 seconds, passed 404 core tests in 15.971 seconds, 21 controller tests in 1.418 seconds and six intake tests in 0.124 seconds. Legacy monitor/save/Reload/Copy/Locate/close/quit compatibility also passed. `source-provenance.json` retained; logs `.local/native-close-integrated-{build,core,controller,intake,monitor}.log`. It excludes then-concurrent NativeDocumentEndpointBindings, which separately passed 23 checks in `.local/native-endpoint-bindings/run.AT0wR6Sx`. No root old test sessions remain active.
3. Latest LOCAL commits: eca3261 endpoint/async reopen26tests; 8757ad6 pinnedfactory133 +historyhelper7; 7fa1e4f nativeclose5includingactualforcedrepair; 1138f30 externalFIFO8aftererrornotificationfix; 4fb15af exactnative navigation32includingactualpending-editred32/2→green; 5cfea3a terminalpositionfailures10FIFOtests. Alllocalonly, noGUIclaims.
4. ROOT owner NativeApplicationDocuments now implemented/reviewed and freshly verified on frozenpre-AppDelegate source. Eighttests/0 in0.749s (.local/native-workspace-eight.log, session59321done). Snapshot .local/native-application-documents-tests/run.LatJK8ny has sources.json plus eight-test-overlays.json; original7testcapacityred5failures preserved .local/native-workspace-capacity-behavior-red.log. Owner includes actual scratch/restoration/claims/history/close/publisher/quit, queuedexternalfiles+positions, windowreservationsbeforeendpointallocation. Testsfull32reservedwindow and128reserveddoc preservingexactsession; imported switched-tab retry is source-reviewed notdirectfault-injected.
5. document_core NOW owns AppDelegate.swift migration plus NEW AppDelegateDocumentsAccess.swift, AppDelegateDocumentsTests.swift, scripts/test-appdelegate-documents.sh. Source activelyediting; do notrunallcurrentnative tests untilagentstable. NewtestDI SessionCoordinator/RecoveryCoordinator andpresentationcallbacks defaultnative; hiddenappdelegate tests mustnotshowwindows. Agentmustremove authoritativeeditorarray/legacypublisher, wireownerFIFOforallCLI/Finder, actualasyncsessionaccept, newwindowerrorhandling, sharedquitandretry. Settingsreapplyafterstartup. Atfull128unresolvedownerstartcanlegitimatelyhavezeroeditorwindows; showrepairpanel,noforcedscratch. Nootheragentmayedittheseownedfiles.
6. Root must finish scopedownercommit/publicrecords, then await AppDelegate frozenbuild/tests. Run fullfrozenapp build+404core+owner8+AppDelegate+controller32+intake6+open10+close5+legacy monitor compatibility asappropriate, recordingexacthashes. AppDelegateactivationisNOTyetverified; latestcommitted appentry stilllegacy whileuncommitted migrationexists. Currentdist remainsf9bd511, mustrefreshafterverifiedcommits.
7. engine_spike andrequirements currentlyidleafterreview. Use followup_task (not send_message) to wake: send_message alone doesnotstartidleagent. engineclearreviewedownercapacity/retry, requirementsclearreviewedclose andFIFO notification; navpendingeditfindingresolvedwithactualred/green. Alltoolrootoldtestsfinished. Root sixFIFO .local/native-workspace-six.log passed6/.989s beforecapacityexpansion.
8. Nextstepsaftermigration: completeeveryremainingmatrixrequirement; do notstopatarchitecturemilestone. GUIblockedbylockedconsole/noresponse; no visibleapps/XCUITest/input/benchmarks untilaccessconfirmed. Localnativehidden/build/tests authorized. No remote pushes/releases/credentials/securitychanges. Keep rawlogs/syntheticfixtures .local ignored.

## Architecture and invariants

AppKit/TextKit1, Foundation/CryptoKit/Darwin PadCore; no external runtime dependencies. macOS 14 minimum; Swift 6.3.3 in explicit Swift 5 mode. Runtime evidence: ARM64 M4 Pro, 48 GiB, macOS 26.6.2 only. Committed `6c7fb68` additionally cross-compiled for x86_64/macOS 14 in 25.69 seconds; no Intel runtime or packaging claim (docs/verification/intel-cross-compilation.md). Engine remains provisional pending full multicursor, performance, IME and accessibility acceptance.

- One shared text storage and undo manager per document; at most two editor views, stable identities and retained detached undo targets. Composition excludes competing edits. Above 2,000,000 UTF-16 units, saved split restoration is explicitly deferred.
- Session v2 persists ordered pane ranges, point scroll origins, axis and focused slot once per logical document. Exact canonical v1 migration is read-only. Native range clamp is synchronous and bounded using existing NSString; full startup/bookmark validation stays off-main. No asynchronous native restore worker or full glyph-layout flush remains. Scroll placement is best effort across font/wrap/geometry changes.
- Registry owns exclusive document/group/window metadata, but native controllers have not migrated. Live limits are 32 windows/128 handles; capacity snapshot also counts unresolved records. Aggregate admission and transfers still require wiring. Close-state tests use synthetic receipts and do not prove durable recovery repair.
- Current legacy RecoveryCoordinator.close permanently tombstones an ID before deletion. Never map its thrown error to unchanged/write-enabled recovery. New managed captures must carry their original epoch; no late getter may upgrade stale work. Preserve model ownership on uncertainty and require fresh confirmed atomic repair before reopening admission.
- Exact dirty comparison retains its conservative fallback and pending-storage poison. No digest-only or unconditional dirty substitute.
- Atomic publication uncertainty retains opaque evidence and attempted bytes; readback is not acknowledgement. Fresh successful save only. Keep Buffer never authorizes overwrite.
- Paired recovery/session checkpoints use 750 ms debounce/15 s maximum, one worker plus pending capture, bounded retry and quit drain/final receipt. Preserve this single publication authority.
- Monitoring uses bounded registration/work queues, exact-byte reconciliation and explicit action ownership. Reload/Copy/Locate maintain final authority checks; monitoring never automatically overwrites files or reloads edits.
- Shortcut settings use one validated atomic catalog, preserve native protected commands and fence composition/extension revisions. Physical keyboard layout behavior is unverified.

## Commands

```sh
scripts/swift.sh build --scratch-path .build/pane-native-integration
scripts/swift.sh test --scratch-path .build/pane-native-integration
scripts/test-session-presentation-flow.sh
scripts/test-session-capacity.sh
scripts/test-application-documents.sh
scripts/test-pane-session.sh .build/pane-native-integration/arm64-apple-macosx/debug
scripts/test-pane-save.sh .build/pane-native-integration/arm64-apple-macosx/debug
scripts/test-native-monitor-lifecycle.sh .build/pane-native-integration/arm64-apple-macosx/debug
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
python3 scripts/check-public.py
git diff --check
scripts/package.sh --ad-hoc-sign
python3 scripts/check-package.py dist/TheOnlyPad.app dist/TheOnlyPad-0.1.0-dev-arm64.zip dist/TheOnlyPad.sbom.json
```

Coordinate shared scratch builds. Raw logs and synthetic fixtures stay ignored in `.local`; no real user documents, machine-specific paths or credentials belong in public records. Repository-local commit identity is configured.

## GUI access and artifacts

An approved read-only console probe on 2026-09-10 confirmed the screen remains locked. The user was asked to unlock and approve UI Automation if prompted; no response yet. Do not run visible apps, benchmarks, posted input or XCUITest until access is confirmed. Hidden AppKit tests and build-for-testing are allowed. Never change credentials/security settings. Earlier UI automation failures do not establish their cause from today's lock state.

Current artifacts are source `f9bd511`: `dist/TheOnlyPad.app`, `dist/TheOnlyPad-0.1.0-dev-arm64.zip`, `dist/TheOnlyPad.sbom.json`. Executable SHA-256 `b18bd4f7f2703c8dc6d261f4b7f833e56d68039630944f4d5e3ef87104974a7a`. Isolated committed-source release build 26.94 seconds; six-file bundle/archive/SBOM checks and strict deep ad-hoc signature checks passed before/after promotion. See `docs/verification/ownership-package.md`. This excludes subsequent close-model, history, prepared-seed and controller integration changes. No Developer ID/notarization/publication or current packaged desktop acceptance. Earlier packaged GUI and Intel cross-build evidence belong to older source/binaries.

## Remaining acceptance

Every outstanding matrix item remains scope: autosave and remaining save faults; advanced editing/multicursor/rectangle/overwrite; folder replacement previews/backups; folding/completion/snippets/custom languages/formatters; workspace/group/window transfer; complete macro bindings/localization/accessibility/IME; repeated cold-launch/100 MB/1 GB/pathological-line performance; security/supply-chain/parity and failure review; clean packaged desktop testing. Historical dirty-edit and checkpoint interaction measurements cover only their recorded operations, not full performance acceptance. Glyph warnings reproduced on baseline and candidate remain unresolved. Intel/minimum-OS runtime and physical IME/VoiceOver are untested. Signing and release require separate external steps.
