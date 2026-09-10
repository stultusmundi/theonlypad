// Appended to the isolated owner source. Every native port still calls its production implementation.
@MainActor var nativeTransferTestHook: ((String) -> Void)?
extension NativeApplicationDocuments {
  private func interceptTransferNative(_ original: ApplicationDocumentTransferNative)
    -> ApplicationDocumentTransferNative
  {
    .init(
      capture: { snapshot in
        nativeTransferTestHook?("capture")
        return try original.capture(snapshot)
      },
      validate: { snapshot, receipt in
        nativeTransferTestHook?("validate")
        try original.validate(snapshot, receipt)
      },
      suspendMonitor: { snapshot, receipt in
        nativeTransferTestHook?("suspend")
        try original.suspendMonitor(snapshot, receipt)
      },
      projectSource: { snapshot, receipt in
        nativeTransferTestHook?("source")
        try original.projectSource(snapshot, receipt)
      },
      projectTarget: { snapshot, receipt in
        nativeTransferTestHook?("target")
        try original.projectTarget(snapshot, receipt)
      },
      attachMonitor: { snapshot, receipt in
        nativeTransferTestHook?("attach")
        try original.attachMonitor(snapshot, receipt)
      },
      refreshAdmission: { receipt in
        nativeTransferTestHook?("refresh")
        try original.refreshAdmission(receipt)
      },
      finishMonitor: { snapshot, receipt in
        nativeTransferTestHook?("finish")
        try original.finishMonitor(snapshot, receipt)
      })
  }
}
