# History-backed document intake

A reopen request carries `DocumentIntakeProvenance.history(DocumentHistoryClaim)`. The claim fixes the retained source, original window and new replacement identity before factory execution. History is not an unresolved-session capacity reservation: intake validates the claim and uses fresh aggregate session capacity admission.

Preflight runs before acquiring publication pause, after draining, and after native factory construction. It requires the exact claim replacement ID and original window, and registry history validation. Missing, evicted or mutated source records refuse before construction when detected at entry. A source changed after registration leaves the strongly owned replacement transaction retained for resolution; it is not generically unregistered after possible actor adoption.

After actor adoption and native authority installation, intake requires exact registry handle, assignment, ownership and active readiness. It then consumes the exact history claim before native projection. The operation records successful consumption in its existing resolution latch. A failed projection may retry without consuming history again, constructing another model or adopting another authority. Registry consumption revalidates the source at that final boundary. Ownership and active readiness are checked again after its notification callback.

Failed adoption or native installation does not consume history. Consumption is a logical ownership action and does not write original files. The retained source and replacement have different document identities and recovery authority. Existing fresh, session and recovery provenance retain their prior behavior.

Scope: process intake support only. Native Reopen menu routing, seed capture from history, endpoint lifetime and application-level acknowledgment remain separate integration work. Tests use synthetic handles and real registry/recovery actor stores; they do not demonstrate visible desktop behavior.
