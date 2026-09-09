extension DocumentFileStateController {
  var monitorHarnessReceipt: MonitorSnapshot? { registration?.snapshot }
  var monitorHarnessInvalidated: Bool { invalidated }
}

extension DocumentFileStateController {
  var monitorHarnessHandle: (any MonitorHandle)? { registration }
}
