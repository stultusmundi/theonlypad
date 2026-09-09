# External open queue implementation plan

1. Define immutable envelope, counted batch admission and completed/refused/retained result contracts. Reviewed before implementation; no AppDelegate changes.
2. Retain a snapshot runner using actual PadCore LaunchRequest and the Foundation queue. Write startup/FIFO/overflow, active/retained capacity, quit/veto, retry identity, waiter cancellation and callback reentry tests against compiling stubs.
3. Observe genuine behavioral red, implement single-task ownership and independent gates, then rerun unchanged tests.
4. Extend acceptance with retry inside notification, strong owned-task lifetime, and retained quit-drain behavior. Format and strictly lint owned Swift files.
5. Independent source review before adopting into AppDelegate. Integration must surface admission counts, map envelope UUID to retained intake operation, and separately test real external delivery, startup, quit veto and native target loss. Passing these queue tests does not satisfy those native requirements.

Run `scripts/test-application-open-requests.sh`. Private snapshots include all source hashes and a bounded process-group watchdog. No GUI, external process launching from requests, or filesystem document access is part of this suite.
