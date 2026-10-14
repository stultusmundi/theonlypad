# Transfer refusal during pending native history clear

Private frozen-source diagnostic, verified on ARM64 macOS on 2026-10-14.
Production adoption and complete native undo acceptance remain outstanding.

The original notification diagnostic observes `isUndoing` during the SDK's
undo notification. It therefore cannot establish the required idle-SDK interval.
A separate read-only trace observation samples the original history-finish
boundary after SDK undo returns and before root publication and pending clear
finish. It correlates the real outer history operation, manager, document and
settlement. Bounded nested trace events grant no outer-operation credit.

One separately selected native test passes with zero failures. At that boundary
both SDK activity flags are false and grouping is zero, while pending clear and
the native inverse actions remain present. After excluding the other busy
conditions, the actual transfer state reports busy and transfer-view capture
refuses. On the original public undo return, pending clear and both inverse
actions are absent. The test then completes its original custody and undo
checks. This is one selected case, not a passing 115-test suite.

A private negative control deletes only the pending-clear term from transfer's
busy predicate. Its other 192 inputs, including the complete test and cleanup
guards, remain exact. The unchanged test reaches the same interval and fails
both the scalar busy assertion and actual transfer-view refusal assertion.
The full result is one failed test with six failure records, including one
unexpected `InvalidTransition` error. Later success-body checks are unentered.
Physical clear is observed and cleanup is attempted, but no terminal cleanup or
empty-custody receipt is established. The unexpected error's cause is not claimed.
The mutant is never a production candidate.

Both runs freeze 193 inputs, compile 191 objects and verify five modules,
227 artifacts and four test-bundle files, with warnings treated as errors.
The four authored modules explicitly use Swift 5 language mode; the generated
SwiftPM test entry has no explicit language-mode argument. Independent review
checks source copies, compiler inputs, link and bundle bindings, exact selected
case identities, complete capture and natural owned-process completion.

Earlier notification-prerequisite failures, compiler failures and the unsafe
historical lifetime case remain preserved and unselected. Budget limits,
redo/nested combinations, witness lifetimes, the complete private producer,
current public-source integration, desktop behavior and performance remain
separate acceptance gates. Raw synthetic evidence stays ignored locally.
