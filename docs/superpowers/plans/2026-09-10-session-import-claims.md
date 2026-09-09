# Session import claim plan

1. Add tests against actual SessionCoordinator for exact/foreign/replayed/stale claims, error-prose tolerance, byte-distinct source paths, pending cleanup/startup/preservation refusal and coherent reentrant resolution.
2. Implement opaque claim validation and metadata ownership handoff without recovery disk writes.
3. Run retained claim tests, existing capacity and restoration-flow compatibility; review before commit.
4. Wire claims into registry import transactions only with reviewed failure reconciliation. This remains separate planned work.

Steps 1–3 implemented and verified: nine claim tests, seven capacity tests and nine restoration-flow tests passed; independent review clear. See [evidence](../../verification/session-import-claims.md). Step 4 remains planned and unimplemented.
