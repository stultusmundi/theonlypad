"""Exact counted frozen-only driver instrumentation; never changes live production."""

def _require_unique(text: str, needle: str) -> None:
    count = text.count(needle)
    if count != 1:
        raise ValueError(f"Driver instrumentation anchor occurs {count} times: {needle!r}")

def transform_driver(source: str) -> str:
  text=source
  needle='    let child = await lifecycle.admissionInspection()'
  _require_unique(text,needle)
  text=text.replace(needle,needle+'\n    await SearchParentDriverTestHooks.afterSettlementInspection?()')
  needle='    withExtendedLifetime(source) {}';_require_unique(text,needle)
  text=text.replace(needle,'    await SearchParentDriverTestHooks.scopeExit?(nonce)\n'+needle)
  needle='        await discardSession(epoch)\n        readOwnerExited(epoch)'
  _require_unique(text,needle)
  text=text.replace(needle,'        await discardSession(epoch)\n        await SearchParentDriverTestHooks.sessionExit?(epoch)\n        readOwnerExited(epoch)')
  needle='        try codec.consume(token: token, bytes: payload.take())'
  _require_unique(text,needle)
  text=text.replace(needle,'        SearchParentDriverTestHooks.beforeConsume?()\n        return try codec.consume(token: token, bytes: payload.take())')
  needle='      await driveAndStage(nonce)'
  _require_unique(text,needle)
  text=text.replace(needle,'      await SearchParentDriverTestHooks.beforeBegin?()\n'+needle)
  needle='    guard old.registration.claim() else'
  _require_unique(text,needle)
  text=text.replace(needle,'    SearchParentDriverTestHooks.beforeClaim?()\n'+needle)
  needle='    return try await withTaskCancellationHandler {'
  _require_unique(text,needle)
  text=text.replace(needle,'    await SearchParentDriverTestHooks.beforeObserverInstall?()\n'+needle)
  needle='      try await upload(current, op: op, source: source)'
  _require_unique(text,needle)
  text=text.replace(needle,'      await SearchParentDriverTestHooks.beforeRequestUpload?()\n'+needle)
  needle='      if let observation {\n        await lifecycle.rejectedChannel(observation, generation: current.generation)'
  _require_unique(text,needle)
  text=text.replace(needle,'      await SearchParentDriverTestHooks.beforeChannelObservation?()\n'+needle)
  needle='        if let ticket = await ready.value() { try? await lifecycle.cancel(ticket) }'
  _require_unique(text,needle)
  text=text.replace(needle,'        if let ticket = await ready.value() {\n          await SearchParentDriverTestHooks.beforeCancelCommand?()\n          try? await lifecycle.cancel(ticket)\n        }')
  needle='    let child = await lifecycle.shutdown()'
  _require_unique(text,needle)
  text=text.replace(needle,'    await SearchParentDriverTestHooks.beforeShutdownCommand?()\n'+needle)
  needle='          while op.decision == nil { await changed() }'
  _require_unique(text,needle)
  text=text.replace(needle,'          SearchParentDriverTestHooks.beforeAuthorityWait?()\n'+needle)
  needle='        observe?(.readHeld(current.generation, bytes.count))'
  _require_unique(text,needle)
  text=text.replace(needle,needle+'\n        await SearchParentDriverTestHooks.readScope?(sequence)\n        withExtendedLifetime(bytes) {}')
  needle='      } else {\n        current.readState = .failed(sequence, nil)\n      }\n    }\n  }\n  private func readScopeExited'
  _require_unique(text,needle)
  text=text.replace(needle,'      } else {\n        current.readState = .failed(sequence, nil)\n      }\n      await SearchParentDriverTestHooks.readScope?(sequence)\n      withExtendedLifetime(error) {}\n    }\n  }\n  private func readScopeExited')
  needle='          observe?(.terminalAccepted(op.handle.nonce))'
  _require_unique(text,needle)
  text=text.replace(needle,'          if SearchParentDriverTestHooks.exhaustReadOnTerminal { current.readSequence = UInt64.max }\n'+needle)
  needle='      try await upload(current, op: op, source: source)\n      try checkDecision(op)'
  _require_unique(text,needle)
  text=text.replace(needle,'      try await upload(current, op: op, source: source)\n      await SearchParentDriverTestHooks.beforeExpect?()\n      try checkDecision(op)')
  needle='    case .needMore, nil: break'
  _require_unique(text,needle)
  text=text.replace(needle,'    case .needMore, nil:\n      if SearchParentDriverTestHooks.exhaustReadOnNeedMore { current.readSequence = UInt64.max }')
  needle='      guard current.enabled else { return nil }'
  _require_unique(text,needle)
  text=text.replace(needle,'      SearchParentDriverTestHooks.heldReadDecision?(current.enabled)\n'+needle)
  text+='\n// Frozen test-only scope hold; absent from candidate production source.\nenum SearchParentDriverTestHooks {\n  static var afterSettlementInspection: (@Sendable () async -> Void)?\n  static var scopeExit: (@Sendable (UUID) async -> Void)?\n  static var sessionExit: (@Sendable (UInt64) async -> Void)?\n  static var beforeConsume: (@Sendable () -> Void)?\n  static var beforeBegin: (@Sendable () async -> Void)?\n  static var beforeClaim: (@Sendable () -> Void)?\n  static var beforeObserverInstall: (@Sendable () async -> Void)?\n  static var beforeRequestUpload: (@Sendable () async -> Void)?\n  static var beforeChannelObservation: (@Sendable () async -> Void)?\n  static var beforeCancelCommand: (@Sendable () async -> Void)?\n  static var beforeShutdownCommand: (@Sendable () async -> Void)?\n  static var beforeAuthorityWait: (@Sendable () -> Void)?\n  static var readScope: (@Sendable (UInt64) async -> Void)?\n  static var exhaustReadOnTerminal = false\n  static var exhaustReadOnNeedMore = false\n  static var beforeExpect: (@Sendable () async -> Void)?\n  static var heldReadDecision: (@Sendable (Bool) -> Void)?\n}\n'
  text+='\nextension SearchParentWireDriver {\n  func testLaneOwnership() async -> (reserved: Bool, executing: Bool) { await state.testLaneOwnership() }\n}\nextension SearchParentDriverState {\n  func testLaneOwnership() -> (reserved: Bool, executing: Bool) { (laneBusy, lane.snapshot.busy) }\n}\n'
  return text


def transform_lifecycle(source: str) -> str:
  needle = '    slot = .absent\n    ownership = nil\n    if let current = operation'
  _require_unique(source, needle)
  replacement = '    slot = .absent\n    ownership = nil\n    SearchChildLifecycleTestHooks.afterAdoptedRelease?(generation)\n    if let current = operation'
  text = source.replace(needle, replacement)
  return text + '\n// Frozen-only nonblocking observation after exact reap and close acknowledgment.\nenum SearchChildLifecycleTestHooks {\n  static var afterAdoptedRelease: (@Sendable (UUID) -> Void)?\n}\n'
