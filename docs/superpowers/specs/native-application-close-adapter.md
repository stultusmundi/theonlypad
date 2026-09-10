# Native application close adapter

NativeApplicationCloseCoordinator is a native adapter around the existing ApplicationDocumentClosing transaction owner. It does not create a registry, recovery store, publisher or second close state machine. The caller supplies the process registry/recovery owner, DocumentClosingPublication, current endpoint lookup, process error reporting and optional native confirmation decision closure. Production confirmation defaults to the actual controller dialog; hidden tests inject responses without presenting it.

Public operations are start(documentIDs:sourceWindowID:), wait(for:), retry(_:), requireSettled(), endpointClosed(windowID:), status and hasUnsettledTransactions. Start requires documents from the original single-group window. The supplied publication admission must enforce process startup/quit and conflicting transaction policy.

Confirmation and legacy drain retain and revalidate the exact endpoint incarnation/controller across suspension. Native admission delegates to applyManagedAdmission. Capture uses the registry-owned EditorDocument and captureCloseRecovery. Repair verifies exact registry repairing IDs, assignment and captured pre-await context before installCloseRepair. Actor lease/publication receipt validation remains in ApplicationDocumentClosing; this wrapper does not manufacture receipts or reread the expected authority after awaiting repair.

Projection uses current registry windows and one workspace revision, validates endpoint identity before/after callback-capable native projection, and refuses missing endpoints. Endpoint loss does not cancel an admitted transaction or recreate its model. Once a replacement endpoint is explicitly installed by the process, Retry can complete projection of the retained result. Error delivery is process-owned, not a callback into a destroyed controller.

Scope: no AppDelegate activation, endpoint-table implementation, new monitor ownership, or GUI automation. The single-group restriction remains explicit. Final application wiring must supply shared publication and settled predicates.
