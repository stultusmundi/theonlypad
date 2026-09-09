# External commands implementation plan

Status: planned. Owner: ExternalCommand.swift, ExternalCommandTests.swift, ExternalCommandController.swift. Root owns menu integration.

1. Test literal argument expansion without recursive substitution or implicit shell evaluation; test missing context and input budgets.
2. Implement a single-use runner with absolute executable path, explicit argument array, null stdin, simultaneous bounded stdout/stderr draining, thirty-second default timeout, and cancellation escalating from TERM to KILL for the launched process only.
3. Test synthetic scripts for argument injection resistance, simultaneous pipe-capacity output, nonzero exit, output cap, timeout, and ignored-TERM cancellation.
4. Add an explicit manual native panel with executable path, one argument per line, Run, Cancel, and selectable output/status. Execution has the user's local permissions; no sandbox or descendant-process containment claim. Never invoke from file/project opening.

API: `CommandContext(path: String?, selection: String, text: String? = nil)`; `ExternalCommandRunner.run(executable:arguments:context:timeout:maximumOutputBytes:) throws -> ExternalCommandResult`, called off main; thread-safe `cancel()`. Native `ExternalCommandController(context:)` owns its runner. Variable expansion is a single pass over original arguments: `${path}`, `${selection}`, `${text}`. Missing/unknown variables fail before process launch. Explicit `/bin/sh` remains allowed and clearly identified as shell execution.

Acceptance is separate for core execution and actual native UI. Synthetic test files only; no credentials, private paths, or automatic project commands.

## Implemented

The runner passes explicit argv to an absolute executable URL, substitutes document variables in one pass without rescanning replacement text, validates 128-argument/1-MB argument budgets and rejects NULs, uses null stdin, and drains stdout/stderr fairly with nonblocking reads and poll. Combined capture defaults to 1 MB (maximum configurable 4 MB); timeout defaults to 30 seconds. Cancel/timeout/output-limit stopping sends TERM, then KILL after a 250 ms grace period if needed. It addresses only the launched process. Pipe capture also stops after a 250 ms grace period if descendants retain inherited descriptors after that process exits, explicitly reporting truncated capture.

The native panel runs only from its Run button, shows the local-permission/no-sandbox boundary, keeps stdout/stderr selectable, reports termination/exit/signal and truncation, and supports cancellation. `onClose` permits root retention of every open controller. `ExternalCommandController.cancelAllAndWait()` sets a shutdown gate before draining active work; root must await it only after committing to quit. Idle panels cannot launch new commands during this wait. Running tasks retain their controller until completion.

## Verification

Tests first failed on absent runner/context types. The complete root build was intermittently blocked by other agents' in-progress workspace and extension types; a `--skip-build` attempt matched **zero tests and is not evidence**. An isolated temporary package containing exact copies of production ExternalCommand.swift and its test file then passed **6 tests, zero failures**. Tests cover literal injection resistance/nonrecursive substitutions, 131,072 bytes each on stdout and stderr without deadlock, nonzero exit 7, output cap, timeout, argument/NUL limits, prelaunch cancellation, reuse rejection, and readiness-confirmed ignored-TERM cancellation terminating with signal 9.

Normal integrated command once all concurrent types exist:

```sh
scripts/swift.sh test --filter ExternalCommandTests
```

Tracked `Tests/NativeIntegration/ExternalCommandHarness.swift` was compiled against the production controller and PadCore, then executed successfully. It verifies manual run, literal variable output, selectable output, Cancel, and shutdown rejection. An independent agent also exercised a TERM-resistant running panel and attempted Run in a second idle panel during shutdown: no second process launched. Native external keyboard/VoiceOver workflows remain unverified.

Outstanding: persistent named external-command configurations and configurable shortcuts; streaming output presentation; process-tree containment (not promised); comprehensive packaged-app/OS-permission workflows. Output text uses UTF-8 replacement decoding for display; retained core result bytes are exact. No credentials/private documents, automatic file-open execution, external publishing, or new dependencies were introduced.
