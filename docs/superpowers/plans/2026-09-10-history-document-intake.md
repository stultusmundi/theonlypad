# History intake implementation plan

1. Add explicit history provenance without changing legacy fresh/session/recovery semantics. Implemented.
2. Validate replacement ID, original window and exact retained source before construction; enforce fresh aggregate capacity. Implemented.
3. Consume only after confirmed active ownership and preserve the consumption latch across projection retries. Revalidate ownership after callback-capable consumption. Implemented.
4. Retain real registry close → actor deletion/retirement → history claim → new actor adoption workflows; exercise stale/evicted source, failed install, projection retry, capacity and activation-time mutation. Completed: all 23 tests passed; see verification record for exact results.
5. Root source review is clear; independent root execution precedes native application activation. No AppDelegate or controller changes belong to this slice.

Command: `scripts/test-application-document-intake.sh`. The runner snapshots dependencies, builds an isolated Swift 5 package, uses a watchdog, and retains unique private logs. A sandbox setup failure is separate from the compiled behavioral red. No GUI is used.
