# Document storage string snapshots — 2026-10-15

`DocumentCommitTextStorage` now retains one immutable string snapshot between character edits. Character replacement clears it before and after the backing mutation. Reads during a reentrant backing mutation bypass the cache; attribute-only edits preserve the character snapshot. Admission, commit sequencing, publication and undo behavior retain their existing paths. This is an internal optimization with a narrow tested contract.

## Verification

`scripts/test-document-text-storage.sh` builds a frozen native test package from actual production sources without access extensions or product-body hooks. Seven fixed cases exercise same-length/ABA/no-op changes, retained Unicode snapshot immutability, mutable-string edits, attributed replacement, attribute-only changes, delete/reinsert and repeated reads. The bounded read case retains32 NSString observations of65,536 ASCII characters and requires at most one identity between edits. This chosen regression contract is not a universal Foundation guarantee or a count of physical copies.

The original producer passes six semantic cases and fails only that identity contract, retaining32 identities. The cached producer passes all seven. Independent source and actual-run reviews accept the narrow results. An unchanged observational diagnostic also records the candidate retaining one identity. Separate pure runner controls pass83; a fresh warnings-as-errors default suite passes1,203 and builds/links the app and helper. Counts describe distinct invocations and must not be added.

Neighboring native regression commands on the cached source pass separately: editor search15, application search4, managed documents73 and macro19. These are hidden native tests with synthetic state, not desktop or physical-input acceptance.

## Limits and known failure

The earlier original2,000,001-character PaneSave case was killed by macOS under memory pressure. Its output did not establish the assertion horizon. The cache checks do not explain that kill, demonstrate the original test passing, establish a copy count, or provide an allocation/RSS bound. A prior prefix diagnostic stopped before loaded text entered native storage; it also establishes no original PaneSave pass. Preserve those failures and do not rerun the hazardous full case without an established safety envelope.

The last verified ad-hoc package remains source `faa02f5`, before this cache. Its one accepted desktop baseline and the older five-workflow desktop selection remain separate from this change. Raw evidence, synthetic state and machine-specific diagnostics remain ignored locally; no release was published.
