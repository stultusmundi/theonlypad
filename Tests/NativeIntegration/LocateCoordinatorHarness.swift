import Foundation
import PadCore

private final class Cancel: ManualHandle {
  let body: @Sendable () -> Void
  init(_ body: @escaping @Sendable () -> Void) { self.body = body }
  func cancel() { body() }
}
@MainActor final class Client: MonitorClient {
  let real: NativeFileMonitorClient?
  var secondMutation: () throws -> Void = {}
  var calls = 0
  var pending: [UUID: @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void] = [:]
  var latest: UUID?
  var identities: [FileTargetIdentity?] = []
  var inlineFailure = false
  init(real: NativeFileMonitorClient? = nil) { self.real = real }
  func register(
    id: UUID, url: URL, baseline: Data, revision: UInt64, boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (FileObservationToken, DiskObservation) -> Void
  ) throws -> any MonitorHandle {
    preconditionFailure("Locate must not register before owner adoption")
  }
  func rebind(id: UUID, url: URL, baseline: Data, revision: UInt64) throws {
    preconditionFailure("Locate must not rebind before owner adoption")
  }
  func requestCheck(id: UUID) { preconditionFailure("Candidate is not original registration") }
  func checkOnce(
    requestID: UUID, id: UUID, url: URL, baseline: Data, revision: UInt64,
    boundIdentity: FileTargetIdentity?,
    receive: @escaping @Sendable (UUID, Result<DiskObservation, MonitorFailure>) -> Void
  ) -> any ManualHandle {
    calls += 1
    latest = requestID
    identities.append(boundIdentity)
    pending[requestID] = receive
    // Synthetic test mutation only: production coordinator performs no filesystem operations.
    if calls == 2 { try! secondMutation() }
    if let real {
      return real.checkOnce(
        requestID: requestID, id: id, url: url, baseline: baseline, revision: revision,
        boundIdentity: boundIdentity, receive: receive)
    }
    if inlineFailure { receive(requestID, .failure(.capacity)) }
    return Cancel { receive(requestID, .failure(.cancelled)) }
  }
}
@MainActor final class Owner {
  var operation: UUID?
  var current = true
  var closed = false
  var refusal = false
  var applied: [(URL, FileTargetIdentity)] = []
  var finishes: [UUID] = []
  var errors = 0
  var currentHook: () -> Void = {}
  var applyHook: () -> Void = {}
  var reportHook: () -> Void = {}
  var callbacks: DocumentLocateCallbacks {
    DocumentLocateCallbacks(
      beginOperation: { [self] in
        guard !refusal else { return nil }
        let id = UUID()
        operation = id
        return id
      },
      isCurrent: { [self] id in
        let valid = current && !closed && operation == id
        currentHook()
        return valid
      },
      apply: { [self] url, identity, _ in
        applied.append((url, identity))
        applyHook()
      },
      finish: { [self] id in
        finishes.append(id)
        if operation == id { operation = nil }
      },
      reportError: { [self] _ in
        errors += 1
        reportHook()
      })
  }
}
@main struct LocateHarness {
  @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
  @MainActor static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("synthetic.txt")
    let bytes = Data("e\u{301} exact saved bytes 😀\r\n".utf8)
    try bytes.write(to: file)
    let observation = try await Task.detached {
      try ExternalFileProbe().observe(
        file, expected: bytes, boundIdentity: nil, forceContents: true, previous: nil,
        isCancelled: { false })
    }.value
    let input = DocumentLocateInput(
      documentID: UUID(), originalURL: directory.appendingPathComponent("missing-original"),
      candidateURL: file, baselineRevision: 1, originalBytes: bytes)
    let application = ApplicationFileMonitoring()
    defer { application.stop() }
    var checks = 0
    func check(_ value: Bool, _ description: String) {
      if !value {
        print("FAIL: \(description)")
        exit(1)
      }
      checks += 1
    }
    let client = Client()
    let owner = Owner()
    let locate = DocumentLocateCoordinator(application: application, client: client)
    check(locate.start(input, callbacks: owner.callbacks), "first captured Locate admitted")
    let first = client.latest!
    let own = owner.operation!
    let other = DocumentLocateCoordinator(application: application, client: client)
    check(
      !other.start(input, callbacks: Owner().callbacks),
      "one process lease bounds Locate across windows")
    client.pending[first]?(first, .success(observation))
    await settle()
    check(
      owner.applied.isEmpty && client.calls == 2 && client.identities[0] == nil
        && client.identities[1] == observation.metadata?.identity,
      "second comparison carries first candidate identity before adoption")
    let second = client.latest!
    client.pending[second]?(second, .success(observation))
    await settle()
    check(
      owner.applied.first?.0 == file && owner.applied.first?.1 == observation.metadata?.identity
        && owner.finishes == [own],
      "stable exact candidate adopted with validated identity and exact finish")
    let pendingInput = DocumentLocateInput(
      documentID: input.documentID, originalURL: input.originalURL,
      candidateURL: input.candidateURL, baselineRevision: input.baselineRevision,
      originalBytes: input.originalBytes, pendingPublicationID: UUID())
    check(
      !locate.start(pendingInput, callbacks: Owner().callbacks),
      "pending publication cannot redirect source")
    let closed = Owner()
    check(locate.start(input, callbacks: closed.callbacks), "close test admitted")
    let closedRead = client.latest!
    let closedOperation = closed.operation!
    closed.closed = true
    client.pending[closedRead]?(closedRead, .failure(.unavailable))
    await settle()
    check(
      closed.applied.isEmpty && closed.errors == 0 && closed.finishes == [closedOperation],
      "closed completion cannot apply or report")
    let stale = Owner()
    check(locate.start(input, callbacks: stale.callbacks), "stale operation admitted")
    let staleRead = client.latest!
    let staleOperation = stale.operation!
    let newOperation = UUID()
    stale.operation = newOperation
    client.pending[staleRead]?(staleRead, .success(observation))
    await settle()
    check(
      stale.applied.isEmpty && stale.finishes == [staleOperation]
        && stale.operation == newOperation, "old finish cannot unfreeze newer operation")
    let canceled = Owner()
    check(locate.start(input, callbacks: canceled.callbacks), "quit cancellation admitted")
    let cancelRead = client.latest!
    application.suspend()
    application.resume()
    client.pending[cancelRead]?(cancelRead, .success(observation))
    await settle()
    check(
      canceled.errors == 0 && canceled.applied.isEmpty && canceled.finishes.count == 1,
      "quit/veto rejects stale callback")
    client.inlineFailure = true
    let inline = Owner()
    check(
      locate.start(input, callbacks: inline.callbacks),
      "inline refusal follows installed transaction")
    await settle()
    check(
      inline.errors == 1 && inline.finishes.count == 1,
      "inline refusal releases operation and lease")
    client.inlineFailure = false
    let predicate = Owner()
    predicate.currentHook = { if locate.activeTransactionID == nil { application.suspend() } }
    check(locate.start(input, callbacks: predicate.callbacks), "terminal reentrancy admitted")
    let predicateRead = client.latest!
    client.pending[predicateRead]?(predicateRead, .failure(.unavailable))
    await settle()
    check(
      predicate.errors == 0 && predicate.finishes.count == 1 && application.isSuspended,
      "terminal predicate cannot report after suspension")
    application.resume()
    let refusal = Owner()
    refusal.refusal = true
    check(
      !locate.start(input, callbacks: refusal.callbacks) && refusal.finishes.isEmpty,
      "begin refusal creates no fabricated finish")
    let replacement = Owner()
    let applying = Owner()
    applying.applyHook = {
      locate.cancel()
      _ = locate.start(input, callbacks: replacement.callbacks)
    }
    check(locate.start(input, callbacks: applying.callbacks), "apply reentry admitted")
    let applyingFirst = client.latest!
    client.pending[applyingFirst]?(applyingFirst, .success(observation))
    await settle()
    let applyingSecond = client.latest!
    client.pending[applyingSecond]?(applyingSecond, .success(observation))
    await settle()
    check(
      applying.finishes.count == 1 && replacement.operation != nil,
      "old apply cleanup preserves reentrant replacement")
    locate.cancel()
    await settle()
    // Actual production checkOnce jobs and synthetic filesystem races.
    for mode in ["stable", "different", "equal-inode", "parent"] {
      let parent = directory.appendingPathComponent(mode)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let candidate = parent.appendingPathComponent("candidate.txt")
      try bytes.write(to: candidate)
      let realClient = Client(real: NativeFileMonitorClient(service: application.service))
      realClient.secondMutation = {
        switch mode {
        case "different": try Data("different".utf8).write(to: candidate, options: .atomic)
        case "equal-inode": try bytes.write(to: candidate, options: .atomic)
        case "parent":
          try FileManager.default.moveItem(
            at: parent, to: directory.appendingPathComponent("old-parent"))
          try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
          try bytes.write(to: candidate)
        default: break
        }
      }
      let realOwner = Owner()
      let coordinator = DocumentLocateCoordinator(application: application, client: realClient)
      let request = DocumentLocateInput(
        documentID: UUID(), originalURL: input.originalURL, candidateURL: candidate,
        baselineRevision: 1, originalBytes: bytes)
      check(
        coordinator.start(request, callbacks: realOwner.callbacks), "real " + mode + " admitted")
      let deadline = Date().addingTimeInterval(8)
      while coordinator.activeTransactionID != nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      check(
        realOwner.finishes.count == 1 && realClient.calls == 2,
        "real " + mode + " completes two bounded comparisons")
      check(
        mode == "stable"
          ? realOwner.applied.count == 1 && realOwner.errors == 0
          : realOwner.applied.isEmpty && realOwner.errors == 1,
        "real " + mode + " exact identity/byte admission")
    }
    check(try Data(contentsOf: file) == bytes, "coordinator does not write candidate bytes")
    print(
      "PASS \(checks) Locate coordinator assertions; controlled callbacks and real file races; no GUI/native owner integration"
    )
  }
}
