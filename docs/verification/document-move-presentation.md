# Presentation after moving a document

After a move settles successfully, AppDelegate asks the process owner to revalidate the captured destination endpoint, current assignment, and selected document, then invokes its window presenter once. Opening a newer move chooser, accepting another move, or entering quit invalidates that completion. A quit veto does not revive the previous completion. If the destination changed, the app reports that the document moved but could not be shown automatically; it does not roll ownership back.

Run the hidden semantic checks with:

```sh
scripts/test-document-move-destination.sh
```

The retained three-test suite covers the canonical command and native chooser controls, actual AppDelegate dispatch through the real transfer owner, exact destination/document presentation, actual newer-chooser dispatch and actual quit/veto suppression, stale-destination warning without rollback, and an empty destination list. The presenter is injected; no window is shown by these tests. Visible activation and keyboard focus still require desktop acceptance.

The missing presentation behavior first failed three assertions (zero presenter calls and no target/document); the implementation passed all three tests. Setup/build success alone is not treated as presentation evidence.

Review regression: actual newer-chooser dispatch and quit followed by an owner veto initially produced five failed assertions because the queued completion retained its generation. Generation rotation at both production entry points corrected this; the test no longer sets generation or quit flags manually.
