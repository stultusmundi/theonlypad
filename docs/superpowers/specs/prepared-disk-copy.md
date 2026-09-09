# Worker-prepared disk copies

Status: implemented in the native action boundary and isolated retained semantic harness; controller application-intake wiring is a separate integration step. This adds no file reader or decoder and does not activate managed document intake.

Every copy reserves the existing process-wide CPU preparation permit before reading, including copies with no pane selections. The already-decoded checked snapshot supplies the immutable NativeDocumentSeed. Preparation computes its UTF-16 count and detects language from the captured final display name off the main actor. A nil captured source name is a standalone legacy compatibility fallback to the checked URL basename. The result enum distinguishes reload snapshots plus resolved selections from copy snapshots plus prepared seeds.

Cancellation invalidates transaction/request authority immediately but a running CPU job retains its permit until actual completion. Late completion cannot apply, report errors or finish a newer operation. Reload retains its existing selection resolution followed by final exact disk revalidation. Copy adopts a checked snapshot without writing or redirecting the original file.

Application copy apply must synchronously validate and consume its source-operation context, reserve process payload capacity, and hand the prepared seed to process intake before returning. Placement uses separately captured target incarnation and selection intent. Later source closure does not abandon an accepted seed. A created-copy status is valid only after activation and projection; the standalone coordinator does not provide that acknowledgment.

Startup file seeds have a single-decode encoded overload sharing private restored metadata validation. The supplied-decoded overload retains consistency checking against supplied bytes. Backup, copy and recovery seeds detect language using their actual display names; explicit restored language overrides remain authoritative. Per-seed size checks do not replace aggregate process admission.
