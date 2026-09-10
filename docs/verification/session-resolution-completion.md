# Session resolution completion

The session panel now awaits its resolution callback before removing a record. It retains the existing generation and closed-panel checks before admission and after the awaited result. The process callback must return only after actual intake acceptance/projection; closing a panel does not cancel a separately owned accepted transaction.

Root ran `scripts/test-session-restoration-completion.sh .build/native-ownership-integrated/arm64-apple-macosx/debug`: ten hidden-panel checks passed in `.local/session-restoration-completion/run.2M0qw6Ax`. Coverage includes held acceptance, failure, semantic refresh, explicit generation updates, closure before handoff and a separately owned operation completing after panel closure. The unchanged legacy visible harness compiled but was not executed. The explicit fire-and-forget red seam produced five failures across seven checks before awaiting completion; no claim that compilation failure was behavioral evidence.

The frozen native integration also built the complete application and passed 404 core tests with the async callback. Existing synchronous legacy closures lift to the async type. Actual AppDelegate managed routing and packaged desktop acceptance remain outstanding.
