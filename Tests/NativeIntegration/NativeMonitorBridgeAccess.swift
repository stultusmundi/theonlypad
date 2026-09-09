extension DocumentFileStateController {
  var monitorHarnessReceipt: MonitorSnapshot? { registration?.snapshot }
  var monitorHarnessInvalidated: Bool { invalidated }
}
