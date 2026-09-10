# Regex helper process feasibility

This is a throwaway architectural probe, not an implemented application feature. Original synthetic Swift source and raw evidence remain ignored in `.local/regex-supervisor-spike`.

A compiled Foundation child builds `(a+)+$`, writes a marker immediately before enumeration, and calls `numberOfMatches` over 200 ASCII `a` characters followed by `!`, without cooperative progress callbacks. The parent starts an owned process group, applies an elapsed-time watchdog, sends termination on expiry, waits/reaps the child, and records the result. Only that child group is signalled. A benign child uses `a+` over the same synthetic input.

| Run | Evidence and result |
|---|---|
| First pathological child, 0.5-second watchdog | Exit 124 after 0.508s, no marker. Startup-ambiguous; does not prove enumeration began. |
| First benign child | Exit 0 after 0.012s, marker and one completed match. |
| Warm pathological child, 2-second watchdog | Exit 124 after 2.008s, pre-enumeration marker present, no completed result. Parent termination/wait returned. |
| Fresh benign child after warm timeout | Exit 0 after 0.006s, marker and one completed match. |

This supports the feasibility of independently terminating and reaping an owned regex child while allowing a subsequent child to succeed. It does not implement or verify persistent IPC, application cancellation, queue fairness, byte budgets, RSS limits, packaging, crash recovery, or full search semantics. Startup and request deadlines must be distinct in the eventual design. Process separation alone is not a sandbox.

The probe ran on the recorded macOS 26.6.2 ARM64 environment with the installed Swift 6.3.3 toolchain. Timings are single feasibility observations, not performance benchmarks or universal guarantees. The application still uses cooperative in-process regex execution; hard containment remains outstanding.

## Scalar-boundary compatibility probe

A separate bounded Foundation child searched one synthetic emoji (two UTF-16 units). Explicit high-surrogate, low-surrogate and high-surrogate-class patterns produced no matches; a dot produced exactly range(0,2). The child completed successfully in 0.468s under a 10-second outer watchdog. Evidence: `.local/regex-scalar-spike/result`.

This supports scalar-boundary validation for these four fixtures only. It does not prove every possible regex produces scalar-aligned ranges. Keep these cases in direct/helper differential coverage and preserve full original UTF-16 coordinates. No application behavior changed.
