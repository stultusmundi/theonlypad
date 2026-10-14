// SPDX-License-Identifier: MIT
import Foundation
import PadCore
import SearchExecution

struct NativeApplicationSearchQuitPreparation: Equatable {
  fileprivate let bridgeNonce: UUID
  fileprivate let recordNonce: UUID
}

enum NativeApplicationSearchPhase: Equatable {
  case notCreated, constructing, open, preparing, prepared, terminal, unavailable
}

enum NativeApplicationSearchRefusal: Error, Equatable {
  case constructionInProgress, quitInProgress, prepared, terminal, retainedUnavailable
  case stalePreparation, vetoResumeRefused
  case terminalAdmission(ApplicationSearchTerminalRefusal)
}

enum NativeApplicationSearchVetoResult: Equatable {
  case resumedNotCreated, resumedOwner
  case refused(NativeApplicationSearchRefusal)
}

enum NativeApplicationSearchSettlement: Equatable { case settled, unsettled }

enum NativeApplicationSearchQuitResult: Equatable {
  case noSearchOwner
  case admissionRefused(raw: ApplicationSearchTerminalRefusal)
  case terminal(
    join: ApplicationSearchJoinID, firstRaw: ApplicationSearchTerminalResult,
    latestRaw: ApplicationSearchTerminalResult, disposition: NativeApplicationSearchSettlement)
}

@MainActor
final class NativeApplicationSearches {
  private enum Construction {
    case bundle(URL)
    case injected(@MainActor () throws -> ApplicationSearchOwner)
  }

  private final class QuitRecord {
    let nonce = UUID()
    let quit: ApplicationSearchQuitID?
    var completionConsumed = false
    var vetoConsumed = false
    var join: ApplicationSearchJoinID?
    var firstRaw: ApplicationSearchTerminalResult?
    var latestRaw: ApplicationSearchTerminalResult?
    var canonicalParent: SearchParentJoinedShutdownResult?

    init(quit: ApplicationSearchQuitID?) { self.quit = quit }

    init(refreshing original: QuitRecord) {
      quit = original.quit
      join = original.join
      firstRaw = original.firstRaw
      latestRaw = original.latestRaw
      canonicalParent = original.canonicalParent
    }
  }

  private let construction: Construction
  private let bridgeNonce = UUID()
  private var owner: ApplicationSearchOwner?
  private var current: QuitRecord?
  private var reservation: UUID?
  private(set) var phase: NativeApplicationSearchPhase = .notCreated
  private(set) var lastTerminalResult: ApplicationSearchTerminalResult?

  init(applicationBundle: URL) { construction = .bundle(applicationBundle) }

  init(ownerFactory: @escaping @MainActor () throws -> ApplicationSearchOwner) {
    construction = .injected(ownerFactory)
  }

  func ownerForFind() throws -> ApplicationSearchOwner {
    if phase == .constructing { throw NativeApplicationSearchRefusal.constructionInProgress }
    guard reservation == nil else { throw NativeApplicationSearchRefusal.quitInProgress }
    switch phase {
    case .open:
      guard let owner, owner.phase == .open else {
        phase = .unavailable
        throw NativeApplicationSearchRefusal.retainedUnavailable
      }
      return owner
    case .notCreated:
      break
    case .prepared:
      throw NativeApplicationSearchRefusal.prepared
    case .terminal:
      throw NativeApplicationSearchRefusal.terminal
    case .constructing:
      throw NativeApplicationSearchRefusal.constructionInProgress
    case .preparing:
      throw NativeApplicationSearchRefusal.quitInProgress
    case .unavailable:
      throw NativeApplicationSearchRefusal.retainedUnavailable
    }
    guard owner == nil else {
      phase = .unavailable
      throw NativeApplicationSearchRefusal.retainedUnavailable
    }
    let intent = UUID()
    reservation = intent
    phase = .constructing
    defer { if reservation == intent { reservation = nil } }
    let created: ApplicationSearchOwner
    do {
      switch construction {
      case .bundle(let bundle):
        let service = try SearchAdmissionService<DocumentSearchCredential>(
          applicationBundle: bundle)
        created = ApplicationSearchOwner(
          backend: SearchAdmissionApplicationBackend(service: service))
      case .injected(let factory):
        created = try factory()
      }
    } catch {
      // No owner returned: only this exact construction can restore the explicit retry state.
      if reservation == intent, phase == .constructing, owner == nil { phase = .notCreated }
      throw error
    }
    // Retain any returned chain before validating it; an unusable one is never replaced.
    owner = created
    guard reservation == intent, phase == .constructing, created.phase == .open else {
      phase = .unavailable
      throw NativeApplicationSearchRefusal.retainedUnavailable
    }
    phase = .open
    return created
  }

  func prepareQuitIfCreated() throws -> NativeApplicationSearchQuitPreparation {
    if phase == .constructing { throw NativeApplicationSearchRefusal.constructionInProgress }
    guard reservation == nil else { throw NativeApplicationSearchRefusal.quitInProgress }
    switch phase {
    case .notCreated:
      guard owner == nil else { throw NativeApplicationSearchRefusal.retainedUnavailable }
      let record = QuitRecord(quit: nil)
      current = record
      phase = .prepared
      return preparation(for: record)
    case .prepared:
      guard let record = current, !record.vetoConsumed else {
        throw NativeApplicationSearchRefusal.stalePreparation
      }
      return preparation(for: record)
    case .terminal:
      guard let original = current, original.join != nil else {
        throw NativeApplicationSearchRefusal.retainedUnavailable
      }
      if !original.completionConsumed { return preparation(for: original) }
      let record = QuitRecord(refreshing: original)
      current = record
      return preparation(for: record)
    case .open:
      break
    case .constructing:
      throw NativeApplicationSearchRefusal.constructionInProgress
    case .preparing:
      throw NativeApplicationSearchRefusal.quitInProgress
    case .unavailable:
      throw NativeApplicationSearchRefusal.retainedUnavailable
    }
    guard let owner, owner.phase == .open else {
      phase = .unavailable
      throw NativeApplicationSearchRefusal.retainedUnavailable
    }
    let intent = UUID()
    reservation = intent
    phase = .preparing
    defer { if reservation == intent { reservation = nil } }
    do {
      let quit = try owner.prepareQuit()
      guard reservation == intent, phase == .preparing, owner.phase == .prepared(quit) else {
        phase = .unavailable
        throw NativeApplicationSearchRefusal.retainedUnavailable
      }
      let record = QuitRecord(quit: quit)
      current = record
      phase = .prepared
      return preparation(for: record)
    } catch {
      if phase == .preparing { phase = owner.phase == .open ? .open : .unavailable }
      throw error
    }
  }

  func resumeAfterVeto(_ preparation: NativeApplicationSearchQuitPreparation)
    -> NativeApplicationSearchVetoResult
  {
    guard let record = matching(preparation) else { return .refused(.stalePreparation) }
    // Terminal custody remains irreversible even during an active observation reservation.
    if record.join != nil || phase == .terminal || owner?.phase == .terminal {
      return .refused(.terminal)
    }
    guard reservation == nil else { return .refused(.quitInProgress) }
    guard phase == .prepared, !record.vetoConsumed else { return .refused(.stalePreparation) }
    record.vetoConsumed = true
    let intent = UUID()
    reservation = intent
    phase = .preparing
    defer { if reservation == intent { reservation = nil } }
    guard let quit = record.quit else {
      guard owner == nil, current === record else {
        phase = .unavailable
        return .refused(.vetoResumeRefused)
      }
      current = nil
      phase = .notCreated
      return .resumedNotCreated
    }
    guard let owner else {
      phase = .unavailable
      return .refused(.vetoResumeRefused)
    }
    let resumed = owner.resumeAfterVeto(quit)
    guard reservation == intent, current === record, resumed, owner.phase == .open else {
      phase = .unavailable
      return .refused(.vetoResumeRefused)
    }
    current = nil
    phase = .open
    return .resumedOwner
  }

  func completeQuit(
    _ preparation: NativeApplicationSearchQuitPreparation,
    afterManagedPreparation prepareManaged: @escaping @MainActor () async throws -> Void
  ) async throws -> NativeApplicationSearchQuitResult {
    guard let record = matching(preparation), !record.vetoConsumed else {
      throw NativeApplicationSearchRefusal.stalePreparation
    }
    guard reservation == nil else { throw NativeApplicationSearchRefusal.quitInProgress }
    guard !record.completionConsumed, phase == .prepared || phase == .terminal else {
      throw NativeApplicationSearchRefusal.stalePreparation
    }
    record.completionConsumed = true
    let intent = UUID()
    reservation = intent
    defer { if reservation == intent { reservation = nil } }
    // This operation's return establishes ordering only, never native publication authority.
    try await prepareManaged()
    try requireCurrent(record, intent: intent)
    guard let quit = record.quit else {
      guard owner == nil, record.join == nil, phase == .prepared else {
        throw NativeApplicationSearchRefusal.retainedUnavailable
      }
      try Task.checkCancellation()
      // Absence stays reserved until the outer caller explicitly rolls back or exits.
      return .noSearchOwner
    }
    guard let owner else { throw NativeApplicationSearchRefusal.retainedUnavailable }
    let join: ApplicationSearchJoinID
    if let existing = record.join {
      join = existing
    } else {
      try Task.checkCancellation()
      switch owner.admitShutdownJoined(after: quit) {
      case .callerRefused(let refusal):
        try requireCurrent(record, intent: intent)
        phase = owner.phase == .prepared(quit) ? .prepared : .unavailable
        return .admissionRefused(raw: refusal)
      case .admitted(let issued):
        try requireCurrent(record, intent: intent)
        record.join = issued
        phase = .terminal
        join = issued
      }
    }
    // The actual owner retains its terminal task. Caller cancellation never cancels it.
    let raw = await owner.observeShutdownJoined(join)
    try requireCurrent(record, intent: intent)
    if record.firstRaw == nil { record.firstRaw = raw }
    record.latestRaw = raw
    lastTerminalResult = raw
    let disposition = settlement(raw, record: record)
    guard let first = record.firstRaw else {
      throw NativeApplicationSearchRefusal.retainedUnavailable
    }
    return .terminal(join: join, firstRaw: first, latestRaw: raw, disposition: disposition)
  }

  private func preparation(for record: QuitRecord) -> NativeApplicationSearchQuitPreparation {
    NativeApplicationSearchQuitPreparation(bridgeNonce: bridgeNonce, recordNonce: record.nonce)
  }

  private func matching(_ preparation: NativeApplicationSearchQuitPreparation) -> QuitRecord? {
    guard preparation.bridgeNonce == bridgeNonce, let record = current,
      record.nonce == preparation.recordNonce
    else { return nil }
    return record
  }

  private func requireCurrent(_ record: QuitRecord, intent: UUID) throws {
    guard reservation == intent, current === record else {
      throw NativeApplicationSearchRefusal.stalePreparation
    }
  }

  private func settlement(
    _ raw: ApplicationSearchTerminalResult, record: QuitRecord
  ) -> NativeApplicationSearchSettlement {
    guard case .observed(.observed(let observation)) = raw else { return .unsettled }
    if record.canonicalParent == nil { record.canonicalParent = observation.parent }
    guard record.canonicalParent == observation.parent,
      case .completed(let parent) = observation.parent,
      parent.ownership == .admitted, parent.laneStop == .acknowledged,
      parent.shutdown.parentLaneSettled, parent.shutdown.retainedParentLanes == 0,
      parent.shutdown.child.stopped,
      observation.driverSettlement == .settled(admissionClosed: true),
      observation.retainedActiveJobs == 0, observation.retainedLeases == 0,
      observation.retainedCharge == 0, observation.reservedRetainedCharge == 0,
      observation.activeCharge == SearchAdmissionProductionAccounting().resident
    else { return .unsettled }
    return .settled
  }
}
