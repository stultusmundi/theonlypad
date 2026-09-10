# Native external-open queue

Eight hidden tests passed in 0.298 seconds. The adapter uses the existing bounded FIFO, reads a
regular file descriptor off the main thread with a 100 MB plus one-byte limit, and awaits actual
managed intake and native position installation. The reader does not promise a local-volume-only
or no-hydration policy.

Actual native tests verify intake/navigation order and retrying the same adopted model and recovery
authority after projection failure and deletion of the source file. Separate controlled cases cover
queue startup/quit/overflow, explicit large-file handling, and already-imported navigation retry
without another seed submission.

Independent review exposed error notification before FIFO failure settlement. A behavioral
regression failed with five assertions concerning busy state, missing failure metadata, and
immediate Retry. Notification now occurs after queue settlement and consumes its pending report
before invoking external callbacks. The eight-test run passes; independent rereview found no
remaining issue in that change.

This verifies the adapter with actual injected native collaborators where stated. Full process-owner
FIFO wiring and AppDelegate/Finder/CLI delivery have separate acceptance tests. No visible desktop
or packaged execution is claimed.
