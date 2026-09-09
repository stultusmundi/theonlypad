# External request queue evidence

The first compiling queue seam ran seven tests with 22 failures (including one expected stub retry error), retained privately in run.mj4cgict. Missing FIFO admission, startup processing, bounds and lifecycle behavior caused the failures. The implemented queue passed the unchanged seven tests in run.kmgvI6VN.

The retained command is `scripts/test-application-open-requests.sh`. It freezes actual PadCore and ApplicationOpenRequests source into a unique private Swift package, preserves input hashes and test output, and propagates a 180-second process-group watchdog failure. Synthetic LaunchRequest values are never opened. It is queue-level evidence only, not native application or desktop execution.

Final formatted source passed ten tests with zero failures in run.fMrzx91E (0.005 seconds test execution). Strict Swift lint, shell syntax and diff whitespace checks passed. The three additional checks cover notification-triggered retry, process ownership after caller release and quit drain returning with a retained head. Source is frozen for independent review; AppDelegate integration remains outstanding.

Root independent verification passed all 10 tests in 0.006 seconds (`.local/open-requests-root.log`). Source review found no material issue. AppDelegate must still surface admission rejection counts and map retained envelope IDs to the exact intake retry.
