# Periodic session checkpoint verification

Status: implemented and under integrated review; full feature acceptance is outstanding.

The application owns one checkpoint scheduler. It captures live recovery text and session metadata synchronously, after cleanup barriers, then submits the immutable values to the recovery actor. A receipt follows successful recovery and session publications. Notifications retain a generation counter, not a queue of full document copies. Ordinary failures remain visible and retry on a later request; quit drains ordinary work and uses the same writer.

Focused production-source evidence:

- Storage and scheduler harnesses passed (local execution21477): exact receipt coverage, stale/closed captures, uncertain session readback, bounded coalescing and shared final publication.
- Window and metadata capture harnesses passed4034: coherent text/selection, unresolved record preservation, cleanup draining, and uncertain Save As retaining recovery even after a return to saved text.
- Application build25597 and hidden ApplicationCheckpointHarness80941 passed: exact temporary recovery/session stores, selection/recent-history changes, session-directory obstruction with no acknowledgement, visible Retry and successful fresh publication, final save and resume after veto.
- Window and session notification harnesses passed focused agent runs. Status rendering does not create another checkpoint request.

Independent review identified a close queued during the second cleanup drain and tab metadata changing during final quit I/O. Both are fixed and independently re-reviewed. Synchronous capture refuses pending or failed cleanup, even with zero windows. Quit freezes tab callbacks and text selection; veto restores prior selection behavior, including repeated cancellation. The expanded window harness passed after a frozen-tab runtime regression failed on the prior code.

Fresh core suite21497 passed199 tests with zero failures (9.053seconds). The expanded native suite21497 also passed, including all new checkpoint harnesses and existing process-kill recovery. Source formatting and public-pattern checks passed1889; six package-promotion tests passed. No new dependency was introduced.

These are in-process native and real-file checks. A separate native three-tab checkpoint writer reached its acknowledgement and was SIGKILLed; a fresh native process restored exact Unicode/mixed-ending text, order, pin, selection and recent history (77343). The runner checked SIGKILL and the acknowledgement marker, with no normal quit. These checks do not establish packaged force-termination behavior, physical input, accessibility, or performance acceptance. Current packaged XCUITest requires macOS user authentication; see [desktop verification](xcuitest-feasibility.md). The local package was regenerated24772 with these changes; runtime acceptance is pending. The strengthened native crash assertion passed32417. Packaging initially exposed linker debug paths; see the packaging review record.

Recovery UUID files and Session.json are separate publications. An interrupted checkpoint can leave newer text with older metadata. In-memory close tombstones do not guarantee durable discard across a crash before the next metadata save. Optional autosave of original files is separate and remains outstanding. The standalone release benchmark completed; see [checkpoint costs](checkpoint-performance.md). Its100 MB publication takes about4.2seconds, requiring investigation.
