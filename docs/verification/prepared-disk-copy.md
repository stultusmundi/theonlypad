# Prepared disk-copy verification

The disk action coordinator now returns a typed reload snapshot/selection result or copy snapshot/native seed. Copy uses the existing bounded preparation worker even without selections; the seed reuses decoded snapshot text and captures the display name. Reload retains final exact snapshot revalidation. Cancellation retains an occupied worker permit until actual completion.

Root independently ran `scripts/test-disk-action-coordinator.sh .build/native-ownership-integrated/arm64-apple-macosx/debug`: 65 assertions passed in `.local/disk-action-coordinator/run.sE3pP6mS`. The harness combines controlled callbacks with the real queued service and synthetic files. The earlier copy-with-empty-selections behavioral failure remains in `.local/disk-action-coordinator/run.kPK8wIyo`. No original assertions were removed. Independent source review found no material issue. ARM64 macOS 26.6.2, Swift 6.3.3; no windows were shown.

Native controller migration and full integration are separate work. The source operation must be consumed synchronously at accepted handoff, and creation must not be announced until process adoption and projection succeed. These coordinator checks do not prove desktop behavior or packaged-app acceptance.
