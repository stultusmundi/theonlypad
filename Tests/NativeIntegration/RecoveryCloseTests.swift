import Foundation
import PadCore
import XCTest

@testable import RecoveryOwner

private final class RecoveryFaultGate: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false
  func arm() {
    lock.lock()
    armed = true
    lock.unlock()
  }
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = armed
    armed = false
    return value
  }
}
final class RecoveryCloseTests: XCTestCase {
  private func fixture() throws -> (URL, RecoveryCoordinator, RecoverySnapshot) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "exact 🧪\r\nsecond\r", encoding: .utf16BE, hasBOM: true)
    return (directory, RecoveryCoordinator(directory: directory), snapshot)
  }
  private func refused(
    _ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await work()
      XCTFail("Must refuse", file: file, line: line)
    } catch {}
  }
  func testAdoptBlocksAllLegacyWritersButOtherIDsWork() async throws {
    let (directory, actor, snapshot) = try fixture()
    try await actor.persist(snapshot, revision: 7)
    let receipt = try await actor.adoptManagedDocument(id: snapshot.id)
    XCTAssertEqual(receipt.authority.documentID, snapshot.id)
    await refused { _ = try await actor.adoptManagedDocument(id: snapshot.id) }
    await refused { try await actor.persist(snapshot, revision: 100) }
    await refused { try await actor.clear(id: snapshot.id, revision: 100) }
    await refused { try await actor.close(id: snapshot.id) }
    let other = RecoverySnapshot(id: UUID(), text: "other", encoding: .utf8, hasBOM: false)
    await refused { try await actor.persistBatch([(other.id, 1, other), (snapshot.id, 100, nil)]) }
    XCTAssertEqual(try RecoveryStore(directory: directory).loadAll(), [snapshot])
    try await actor.persist(other, revision: 1)
    XCTAssertEqual(try RecoveryStore(directory: directory).loadAll().count, 2)
  }
  func testOldHigherRevisionCannotWriteAfterRepair() async throws {
    let (directory, actor, snapshot) = try fixture()
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    let old = AuthorizedRecoveryItem(authority: adopted.authority, revision: 1, snapshot: snapshot)
    try await actor.persistAuthorized(old)
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 10, registryTicketID: UUID())
    XCTAssertEqual(
      try RecoveryStore(directory: directory).loadAll(), [snapshot], "prepare is nondestructive")
    await refused { try await actor.persistAuthorized(old) }
    _ = try await actor.finalizeClose(lease)
    var fresh = snapshot
    fresh.text = "fresh\u{0}👩🏽‍💻\r\n"
    let repaired = try await actor.restoreAfterClose(
      lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: fresh)
    XCTAssertNotEqual(repaired.authority, adopted.authority)
    await refused {
      try await actor.persistAuthorized(
        .init(authority: adopted.authority, revision: UInt64.max, snapshot: snapshot))
    }
    try await actor.persistAuthorized(
      .init(authority: repaired.authority, revision: repaired.nextRevision, snapshot: fresh))
    XCTAssertEqual(try RecoveryStore(directory: directory).loadAll(), [fresh])
    await refused {
      _ = try await actor.restoreAfterClose(
        lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    }
  }
  func testWholeAuthorizedBatchRefusesBeforeAnyPublication() async throws {
    let (directory, actor, snapshot) = try fixture()
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    let wrong = RecoveryWriteAuthority(coordinatorID: UUID(), documentID: UUID(), epoch: UUID())
    await refused {
      try await actor.persistAuthorizedBatch([
        .init(authority: adopted.authority, revision: 1, snapshot: snapshot),
        .init(authority: wrong, revision: 1, snapshot: nil),
      ])
    }
    XCTAssertTrue(try RecoveryStore(directory: directory).loadAll().isEmpty)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    await refused {
      try await actor.persistAuthorized(
        .init(authority: adopted.authority, revision: 1, snapshot: nil))
    }
    await refused {
      _ = try await actor.prepareClose(
        authority: adopted.authority, minimumRevision: 0, registryTicketID: UUID())
    }
  }
  func testCheckpointNeverAcknowledgesLegacyManagedOrStaleAuthority() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let sessionStore = SessionStore(directory: directory.appendingPathComponent("Session"))
    let actor = RecoveryCoordinator(
      directory: directory.appendingPathComponent("Recovery"),
      saveCheckpointSession: { try sessionStore.save($0) })
    let id = UUID()
    let snapshot = RecoverySnapshot(id: id, text: "checkpoint", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: id)
    let session = EditorSession(windows: [.init(tabs: [.init(id: id)], selectedTabID: id)])
    let legacy = SessionCheckpointCapture(
      generation: 1, liveTabIDs: [id], recovery: [.init(id: id, revision: 1, snapshot: snapshot)],
      session: session)
    await refused { _ = try await actor.commitSessionCheckpoint(legacy) }
    XCTAssertNil(try sessionStore.load())
    let valid = SessionCheckpointCapture(
      generation: 1, liveTabIDs: [id],
      recovery: [.init(id: id, revision: 1, snapshot: snapshot, authority: adopted.authority)],
      session: session)
    let result = try await actor.commitAuthorizedSessionCheckpoint(valid)
    XCTAssertEqual(result.recoveryAuthorities, [id: adopted.authority])
    XCTAssertEqual(try sessionStore.load(), session)
    _ = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 1, registryTicketID: UUID())
    let stale = SessionCheckpointCapture(
      generation: 2, liveTabIDs: [id],
      recovery: [
        .init(id: id, revision: UInt64.max, snapshot: snapshot, authority: adopted.authority)
      ], session: session)
    await refused { _ = try await actor.commitAuthorizedSessionCheckpoint(stale) }
  }
  func testRepairPublicationUncertaintyRequiresFreshWriteAndKeepsOldEpochRevoked() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let fault = RecoveryFaultGate()
    let actor = RecoveryCoordinator(
      directory: directory,
      saveRecovery: { store, snapshot in
        try store.save(snapshot, fault: fault.take() ? .directorySync : nil)
      })
    let snapshot = RecoverySnapshot(id: UUID(), text: "repair 🧪", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 1, registryTicketID: UUID())
    let priorDeletion = try await actor.finalizeClose(lease)
    fault.arm()
    await refused {
      _ = try await actor.restoreAfterClose(
        lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    }
    XCTAssertEqual(
      try RecoveryStore(directory: directory).loadAll(), [snapshot],
      "published bytes alone do not reopen authority")
    await refused { try await actor.retireClose(priorDeletion) }
    await refused { _ = try await actor.finalizeClose(lease) }
    await refused {
      try await actor.persistAuthorized(
        .init(authority: adopted.authority, revision: 999, snapshot: snapshot))
    }
    let repaired = try await actor.restoreAfterClose(
      lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    XCTAssertNotEqual(repaired.authority, adopted.authority)
  }
  func testOtherWriterValidationDoesNotLoseRepairPublicationState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let fault = RecoveryFaultGate()
    let actor = RecoveryCoordinator(
      directory: directory,
      saveRecovery: { store, snapshot in
        try store.save(snapshot, fault: fault.take() ? .directorySync : nil)
      })
    let snapshot = RecoverySnapshot(id: UUID(), text: "repair A", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 1, registryTicketID: UUID())
    _ = try await actor.finalizeClose(lease)
    fault.arm()
    await refused {
      _ = try await actor.restoreAfterClose(
        lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    }
    let other = RecoverySnapshot(id: UUID(), text: "writer B", encoding: .utf8, hasBOM: false)
    try await actor.persist(other, revision: 1)
    let repaired = try await actor.restoreAfterClose(
      lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    XCTAssertNotEqual(repaired.authority, adopted.authority)
    XCTAssertEqual(
      Set(try RecoveryStore(directory: directory).loadAll().map(\.id)), [snapshot.id, other.id])
  }
  func testSuccessfulRepairPublicationBeforeParentFailureCanRetryOriginalParent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let original = directory.appendingPathExtension("original")
    let replacement = directory.appendingPathExtension("replacement")
    addTeardownBlock {
      for url in [directory, original, replacement] { try? FileManager.default.removeItem(at: url) }
    }
    let fault = RecoveryFaultGate()
    let actor = RecoveryCoordinator(
      directory: directory,
      saveRecovery: { store, snapshot in
        try store.save(snapshot)
        if fault.take() {
          try FileManager.default.moveItem(at: directory, to: original)
          try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        }
      })
    let snapshot = RecoverySnapshot(
      id: UUID(), text: "exact original parent", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 1, registryTicketID: UUID())
    _ = try await actor.finalizeClose(lease)
    fault.arm()
    await refused {
      _ = try await actor.restoreAfterClose(
        lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    }
    await refused {
      _ = try await actor.restoreAfterClose(
        lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    }
    try FileManager.default.moveItem(at: directory, to: replacement)
    try FileManager.default.moveItem(at: original, to: directory)
    let repaired = try await actor.restoreAfterClose(
      lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    XCTAssertNotEqual(repaired.authority, adopted.authority)
    XCTAssertEqual(try RecoveryStore(directory: directory).loadAll(), [snapshot])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: replacement.path).isEmpty)
  }
  func testRemovalUncertaintyBlocksQuotaAndCanRepairExactLease() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let fault = RecoveryFaultGate()
    let actor = RecoveryCoordinator(
      directory: directory,
      removeRecovery: { store, id in
        try store.removeChecked(id: id, fault: fault.take() ? .afterRename : nil)
      })
    let snapshot = RecoverySnapshot(id: UUID(), text: "held", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 1, registryTicketID: UUID())
    fault.arm()
    await refused { _ = try await actor.finalizeClose(lease) }
    let other = RecoverySnapshot(id: UUID(), text: "other", encoding: .utf8, hasBOM: false)
    await refused { try await actor.persist(other, revision: 1) }
    _ = try await actor.restoreAfterClose(
      lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    XCTAssertEqual(try RecoveryStore(directory: directory).loadAll(), [snapshot])
    try await actor.persist(other, revision: 1)
  }
  func testAuthorizedClearUsesCheckedRemovalAndReservesFailedRevision() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let fault = RecoveryFaultGate()
    let actor = RecoveryCoordinator(
      directory: directory,
      removeRecovery: { store, id in
        try store.removeChecked(id: id, fault: fault.take() ? .afterRename : nil)
      })
    let snapshot = RecoverySnapshot(id: UUID(), text: "clear", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    fault.arm()
    await refused {
      try await actor.persistAuthorized(
        .init(authority: adopted.authority, revision: 2, snapshot: nil))
    }
    await refused {
      try await actor.persistAuthorized(
        .init(authority: adopted.authority, revision: 2, snapshot: snapshot))
    }
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 3, snapshot: nil))
    XCTAssertTrue(try RecoveryStore(directory: directory).loadAll().isEmpty)
  }
  func testRepairPreflightChecksRealQuotaWithoutRevokingAuthority() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let actor = RecoveryCoordinator(
      directory: directory, limits: .init(maximumSnapshotUTF16: 10, maximumRestoredUTF16: 10))
    let other = RecoverySnapshot(id: UUID(), text: "123456789", encoding: .utf8, hasBOM: false)
    try await actor.persist(other, revision: 1)
    let snapshot = RecoverySnapshot(id: UUID(), text: "12", encoding: .utf8, hasBOM: false)
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    await refused {
      try await actor.preflightRepair(authority: adopted.authority, snapshot: snapshot)
    }
    try await actor.clear(id: other.id, revision: 2)
    try await actor.preflightRepair(authority: adopted.authority, snapshot: snapshot)
    XCTAssertTrue(try RecoveryStore(directory: directory).loadAll().isEmpty)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
  }
  func testNewAuthorityCanStartAnotherRepairCycleWithSameRegistryTicket() async throws {
    let (_, actor, snapshot) = try fixture()
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    let ticketID = UUID()
    let first = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 0, registryTicketID: ticketID)
    let repaired = try await actor.restoreAfterClose(
      first, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    let second = try await actor.prepareClose(
      authority: repaired.authority, minimumRevision: repaired.nextRevision,
      registryTicketID: ticketID)
    XCTAssertNotEqual(first, second)
    await refused { _ = try await actor.finalizeClose(first) }
    _ = try await actor.restoreAfterClose(
      second, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
  }
  func testForgedDeletionIDCannotRetireExactLease() async throws {
    let (_, actor, snapshot) = try fixture()
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 0, registryTicketID: UUID())
    let receipt = try await actor.finalizeClose(lease)
    await refused { try await actor.retireClose(.init(lease: lease, deletionID: UUID())) }
    _ = try await actor.restoreAfterClose(
      lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    await refused { try await actor.retireClose(receipt) }
  }
  func testExactFinalizationAndRetirementCannotRepair() async throws {
    let (directory, actor, snapshot) = try fixture()
    let adopted = try await actor.adoptManagedDocument(id: snapshot.id)
    try await actor.persistAuthorized(
      .init(authority: adopted.authority, revision: 1, snapshot: snapshot))
    let lease = try await actor.prepareClose(
      authority: adopted.authority, minimumRevision: 1, registryTicketID: UUID())
    let forged = RecoveryCloseLease(
      authority: lease.authority, transactionID: UUID(), registryTicketID: lease.registryTicketID)
    await refused { _ = try await actor.finalizeClose(forged) }
    let result = try await actor.finalizeClose(lease)
    let repeated = try await actor.finalizeClose(lease)
    XCTAssertEqual(result, repeated)
    XCTAssertTrue(try RecoveryStore(directory: directory).loadAll().isEmpty)
    try await actor.retireClose(result)
    try await actor.retireClose(result)
    await refused {
      _ = try await actor.restoreAfterClose(
        lease, attemptID: UUID(), mutationGeneration: UUID(), snapshot: snapshot)
    }
  }
}
