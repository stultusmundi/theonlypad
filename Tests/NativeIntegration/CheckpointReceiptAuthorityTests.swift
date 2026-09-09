import Foundation
import PadCore
import XCTest

@testable import CheckpointPause

final class CheckpointReceiptAuthorityTests: XCTestCase {
  @MainActor private func publish(
    items: [RecoveryCheckpointItem], authorities: [UUID: RecoveryWriteAuthority]
  ) async throws -> SessionCheckpointReceipt {
    let scheduler = SessionCheckpointCoordinator(
      capture: { generation in
        SessionCheckpointCapture(
          generation: generation, liveTabIDs: Set(items.map(\.id)), recovery: items,
          session: EditorSession(windows: []))
      },
      commit: { capture in
        SessionCheckpointReceipt(
          generation: capture.generation,
          recoveryRevisions: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.revision) }),
          recoveryAuthorities: authorities)
      }, delay: { _ in await Task.yield() })
    scheduler.startAfterRestoration()
    await scheduler.pauseAndDrain()
    return try await scheduler.commitFinal()
  }

  @MainActor func testExactCapturedAuthoritiesAcknowledged() async throws {
    let id = UUID()
    let authority = RecoveryWriteAuthority(coordinatorID: UUID(), documentID: id, epoch: UUID())
    let item = RecoveryCheckpointItem(id: id, revision: 7, snapshot: nil, authority: authority)
    let receipt = try await publish(items: [item], authorities: [id: authority])
    XCTAssertEqual(receipt.recoveryAuthorities, [id: authority])
  }

  @MainActor func testMissingStaleForeignAndExtraAuthoritiesRefused() async throws {
    let id = UUID()
    let authority = RecoveryWriteAuthority(coordinatorID: UUID(), documentID: id, epoch: UUID())
    let stale = RecoveryWriteAuthority(
      coordinatorID: authority.coordinatorID, documentID: id, epoch: UUID())
    let foreign = RecoveryWriteAuthority(
      coordinatorID: UUID(), documentID: id, epoch: authority.epoch)
    let item = RecoveryCheckpointItem(id: id, revision: 7, snapshot: nil, authority: authority)
    let extraID = UUID()
    for map in [[:], [id: stale], [id: foreign], [id: authority, extraID: authority]] {
      do {
        _ = try await publish(items: [item], authorities: map)
        XCTFail("A receipt must identify exactly the authority captured for every managed item")
      } catch CheckpointSchedulerError.invalidReceipt {}
    }
  }

  @MainActor func testAuthorityBoundToDifferentDocumentRefusedEvenWhenEchoed() async throws {
    let id = UUID()
    let authority = RecoveryWriteAuthority(coordinatorID: UUID(), documentID: UUID(), epoch: UUID())
    do {
      _ = try await publish(
        items: [.init(id: id, revision: 1, snapshot: nil, authority: authority)],
        authorities: [id: authority])
      XCTFail("A copied authority must not acknowledge another document")
    } catch CheckpointSchedulerError.invalidReceipt {}
  }

  @MainActor func testLegacyReceiptCannotIntroduceUncapturedAuthority() async throws {
    let id = UUID()
    let item = RecoveryCheckpointItem(id: id, revision: 1, snapshot: nil)
    _ = try await publish(items: [item], authorities: [:])
    do {
      _ = try await publish(
        items: [item],
        authorities: [id: .init(coordinatorID: UUID(), documentID: id, epoch: UUID())])
      XCTFail("Legacy capture cannot acknowledge an authority obtained after capture")
    } catch CheckpointSchedulerError.invalidReceipt {}
  }
}
