# External open-request FIFO

Status: implemented as an isolated Foundation-testable queue; AppDelegate and native opening are not integrated by this change. Independent review is required before native migration.

ApplicationOpenRequests owns at most 128 immutable LaunchRequest envelopes, including the currently processing or retained request. Each accepted envelope receives a stable UUID. Admission accepts the FIFO prefix that fits and returns exact accepted, overflow-rejected and quit-rejected counts. The caller must surface rejection counts; this queue performs no UI reporting. Already parsed requests retain their URL, line and column exactly. The queue does not validate/read files or execute commands.

Processing starts only after startupFinished and outside the quit gate. One process-owned task invokes the supplied async processor. The current envelope and task are installed before callbacks or notifications. Completed and explicitly refused outcomes remove the current item; retained outcomes keep it at the head and do not automatically retry. retryCurrent reuses the same envelope ID. The processor must map that ID to its retained intake operation and retry it, rather than creating another model or adopting twice.

beginQuit synchronously closes admission and prevents starting queued work; an already admitted active task is not cancelled. drainCurrent awaits only the task captured at entry, including when it settles to a retained outcome. It does not wait for retained state to disappear or for successors. Cancellation of a waiting task does not cancel process ownership. resumeAfterVeto preserves the independent startup gate and retained head. New arrivals during quit are explicitly rejected; queued requests are retained.

onChange observes coherent state. Completion performs no cleanup after invoking it, because notification may synchronously retry, enqueue or change the quit gate. A retained failure and its immutable envelope survive loss of a native destination; endpoint repair belongs to the processor and explicit retry. This queue does not own or recreate windows. A task that never settles retains process ownership intentionally; native collaborators need their own bounded cancellation/reconciliation contracts.

lastFailure records the most recent refused/retained result with its envelope ID, even after later success. It is diagnostic state, not a current-request success/failure indicator. isProcessing and currentID describe live ownership. No queue cancellation/discard API is exposed in this slice.
