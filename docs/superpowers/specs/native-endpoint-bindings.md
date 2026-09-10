# Native endpoint binding retention

Implemented bounded component; process/controller wiring remains separate. The process table holds monitor authority while registry, intake, or history owns each document. It never owns a model strongly.

`NativeDocumentEndpointBindings(maximumRecords:)` accepts 1...448 records: 128 live documents plus 32 windows with ten retained history entries each. `detach(_:)` retains the exact bridge and actual detachment receipt or error before returning. Duplicate same-model detachment is idempotent. Capacity refuses before bridge access. `reattach(_:liveContext:onChange:)` accepts only the original model, bridge, URL, binding revision and ownership generation. `status(documentID:)`, `retainedCount`, and `purgeReleasedModels()` expose retained state and remove entries whose owner has released the model. Missing file state is a no-op only without a retained entry.

Callbacks cannot recursively consume a transitioning entry. Reattachment coalesces rendering until exact success removes the old entry; no cleanup follows external rendering, which may create a newer detachment. A failure after the bridge accepted its first context is retained as blocked reconciliation, never retried with a fabricated receipt. Ordinary pre-consumption refusal can retry the same receipt. Callers must supply non-owning endpoint callbacks; wrappers themselves capture weak model/bridge and independent attempt state, never the retained entry.

The original baseline fence applies during transition only. After commit each live-context callback captures and validates the current baseline before and after invocation, while preserving original model/bridge/ownership identity. This permits subsequent acknowledged saves. Changed detached baselines refuse; no automatic baseline adoption is performed.

No native window migration, registry activation, or physical GUI acceptance is claimed. A blocked post-consumption failure needs explicit process reconciliation; this component deliberately offers no guessed repair action.
