# Native endpoint binding verification

Command: `scripts/test-native-endpoint-bindings.sh .build/native-ownership-integrated/arm64-apple-macosx/debug`

The runner snapshots actual native dependencies and records source/core hashes in ignored private run directories. It requires an existing PadCore module and object files when a build path is supplied. Compilation has a 120-second watchdog; the hidden synthetic-file harness has a 30-second watchdog. No window is shown, activated, or driven through posted input.

Initial compiled seam failed the named valid-detachment assertion. The first implementation passed, then an added genuine regression showed that a permanent original-baseline fence refused detachment after a later acknowledged save. The transition-only fix passed that case together with retry and reentry controls. Expanded run passed 23 checks, including actual service/bridge detach, old callback release, post-consumption invalidation, refusal without guessed retry, capacity refusal before touching a second bridge, and weak model plus bridge release after committed reattachment.

Private evidence: initial behavioral red `run.458SzTiu`, baseline red `run.rjDam9fY`, expanded green `run.CT2bRllm` under `.local/native-endpoint-bindings`. Earlier compiler isolation diagnostics are separate from behavioral reds. Final formatted runner `run.SD98o7or` also passed all 23 checks with compile/runtime exit 0. Strict formatter lint passed for the two owned Swift files. This establishes the component boundary, not application migration or physical GUI acceptance.

Root independently passed all 23 native checks in `.local/native-endpoint-bindings/run.AT0wR6Sx` (`.local/native-endpoint-bindings-root.log`). Independent source review found no material issue within this component. Controller recreation and process integration remain separate acceptance work.
