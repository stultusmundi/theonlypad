# Document integrity plan

Planned: strict Unicode and explicit legacy decoding; atomic expected-content saves; private checksummed recovery. Public interfaces are synchronous and must be called away from the main thread. No third-party dependencies.

1. Write byte fixture and malformed-input tests, observe missing implementation failure, implement codec, verify randomized Unicode round trips.
2. Write real temporary-file tests for conflict, permissions, symlinks and interrupted saves; implement sibling temporary write and atomic rename.
3. Write recovery integrity/quarantine/private permissions tests; implement versioned snapshots.
4. Run `swift test --filter Document --scratch-path .build/core`, review limitations, record evidence.

Implemented/tested/blocked states are recorded in `docs/verification/document-core.md`. GUI lifecycle integration, force termination and actual disk exhaustion require separate evidence.
