# Registry pending-adoption verification

Pending registry records retain their exact model and refuse editing, close, group mutation and ready capture until adoption completes. Exact request/attempt/assignment/ownership correlation protects retry and activation. Active status records readiness only; the model and recovery actor retain current writer authority, including after repair.

`scripts/test-document-adoption.sh` independently passed 41 XCTest cases: 11 adoption cases and all 30 existing registry cases, in 0.023 seconds. Evidence: `.local/document-adoption-root.log`. The original registry runner separately passed all 30 after its explicit PadCore dependency update. Behavioral red retained 39 tests with nine adoption failures; an earlier fixture compilation error is not behavioral evidence. Actual RecoveryCoordinator identity and adoption receipt are exercised; there is no invented expected coordinator UUID. Independent source review found no material issue.

A frozen full application build and 404 PadCore tests passed with the new registry and process-owned close coordinator; core execution took 16.368 seconds. Source manifest: `.local/adoption-close-integrated/source-provenance.json`; log `.local/adoption-close-integrated.log`. This snapshot uses committed SessionCoordinator and excludes the later recovery-only claim extension. Runtime platform is ARM64 macOS 26.6.2, Swift 6.3.3 in Swift 5 mode.

Native controllers and AppDelegate have not adopted this registry path. Passing registry and core tests does not establish native intake, close, transfer or desktop acceptance.

Neighbor verification: the process-close runner passed all 19 tests against this registry in 0.050 seconds (`.local/adoption-closing-compat.log`), including actual post-close paired publication.
