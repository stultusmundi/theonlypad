# Native language catalog read ownership

The production read owner loads the custom-language catalog off the main thread, publishes immutable confirmed state, and preserves the last good publication after a failed reload. It rejects concurrent requests without queuing, fences callback reentry, and withdraws authority before joining actual worker completion. Construction performs no I/O. This standalone component is adopted locally; application startup, manager/picker wiring, highlighter propagation and desktop acceptance remain outstanding.

## Reproduction

```sh
scripts/test-native-language-catalog.sh
python3 -B -m unittest discover -s Tests/NativeIntegration -p 'test_*.py'
```

The native command owns its direct watchdog stages. Do not put another session-owning watchdog around it. It uses synthetic temporary catalog files and no visible windows. The default SwiftPM suite does not include these retained native tests.

## Verified results on 15 October 2026

The fixed native command passes fourteen unique tests, with zero failures, unexpected failures or skips. All four stages finish naturally with complete capture. The runner freezes 69 original inputs and 139 copies/generated input rows; the compiler proof binds four modules, 63 objects and 103 artifacts. Original and frozen input identities, membership, bundle bytes and compiler artifact identities remain unchanged through final postflight. The formatted retained test files are the bytes actually executed.

Coverage includes real missing/populated/corrupt stores, off-main reads, main-thread notifications, last-good preservation, retry, busy refusal, synchronous loading/terminal callback reentry, invalidation, held-worker joining and cancellation of a joining caller. A genuine inert baseline previously produced thirteen failing methods and eighteen ordinary assertions; its lazy-construction check already passed.

The runner’s six pure contract tests pass separately after an inert baseline of six failing methods and seventeen ordinary assertions. Full NativeIntegration Python discovery separately passes 106 tests. The six new tests use non-executable temporary text fixtures for compiler filelist/output-map/link substitution, exact stage planning, closed CLI and result parsing. The last malformed-result consistency assertion was not reached in the baseline; it is reached in the passing implementation.

A separate frozen application candidate containing this owner and the two formatted tests builds the actual application/helper and passes all 1,203 default tests without compiler warnings. Its existing 623 archived inputs and three additions remain exact. The build confirmation was incremental; no clean-rebuild claim is made. Independent source and actual-run reviews accept the fixed component command (ac2e94a7) and separate application candidate (bd44ecf6).

## Evidence qualifications

The first application inventory observer rejected formatter import sorting; the corrected observer verified unchanged import sets and test bodies. The first native result observer guessed incorrect nested receipt field names. Both observer failures are retained separately from the successful native commands; neither changed production source, tests or receipts.

Raw synthetic logs and machine-specific paths stay in ignored local evidence. This work adds no dependencies or assets. Original code and new source remain MIT-licensed. These results establish no packaged runtime, GUI, performance, physical keyboard, IME or accessibility acceptance.
