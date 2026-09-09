import Foundation
import PadCore

struct ShortcutServices: Sendable {
  var read: @Sendable () throws -> ShortcutStoreRead
  var write: @Sendable (ShortcutProfile, ShortcutReceipt) throws -> ShortcutReceipt
  var validate: @Sendable (ShortcutPublicationUncertain) throws -> Void
  var compose: @Sendable ([CommandDescriptor], ShortcutProfile, UUID) throws -> ShortcutComposition
  init(store: ShortcutStore) {
    read = { try store.read() }
    write = { try store.write($0, matching: $1) }
    validate = {
      try AtomicFileStore().validatePublication($0.evidence, expected: $0.attemptedBytes)
    }
    compose = { try ShortcutComposer.build(catalog: $0, profile: $1, catalogRevision: $2) }
  }
}
enum ApplicationShortcutError: Error, LocalizedError {
  case busy, notLoaded, repairAuthorizationRequired, pendingPublication, conflictingProfile,
    changedPublication
  var errorDescription: String? {
    let message: String
    switch self {
    case .busy:
      message =
        "Shortcut settings are still being processed. Wait for the current operation to finish and try again."
    case .notLoaded:
      message =
        "Shortcut settings are not ready for this action. Reload the stored settings and try again."
    case .repairAuthorizationRequired:
      message =
        "Stored shortcut settings could not be read. Confirm replacing them by importing valid settings or restoring defaults."
    case .pendingPublication:
      message =
        "The last shortcut save was not confirmed. Use Verify and Retry, or explicitly reload and discard the pending changes, before saving again."
    case .conflictingProfile:
      message =
        "Some shortcut assignments conflict with other commands or protected system shortcuts. Resolve the listed conflicts before applying."
    case .changedPublication:
      message =
        "Stored shortcut settings changed after the unconfirmed save. Reload and review them before replacing any settings."
    }
    return NSLocalizedString(message, comment: "Shortcut settings operation error")
  }
}

enum ShortcutOwnerIssue: Equatable {
  case invalidStoredProfile, readFailure, writeFailure, uncertainPublication, invalidCatalog
  case conflicts([ShortcutConflict])
}
struct ShortcutOwnerState {
  let catalog: [CommandDescriptor]
  let catalogRevision: UUID
  let profileRevision: UUID
  let profile: ShortcutProfile
  let composition: ShortcutComposition?
  let issues: [ShortcutOwnerIssue]
  let isBusy: Bool
  let hasPendingPublication: Bool
  var canQuit: Bool { !isBusy && !hasPendingPublication }
}
/// One application-lifetime owner. UI dismissal must not cancel an authorized write.
@MainActor final class ApplicationShortcuts {
  private struct Pending {
    let uncertainty: ShortcutPublicationUncertain
    let profile: ShortcutProfile
  }
  private let services: ShortcutServices
  private var catalog: [CommandDescriptor]
  private var catalogRevision = UUID()
  private var operation: UUID?
  private var receipt: ShortcutReceipt?
  private var profile = ShortcutProfile.defaults
  private var profileRevision = UUID()
  private var composition: ShortcutComposition?
  private var pending: Pending?
  private var invalidStoredProfile = false
  private var storageIssue: ShortcutOwnerIssue?
  private var catalogIssue: ShortcutOwnerIssue?
  var onChange: (() -> Void)?
  var state: ShortcutOwnerState {
    var issues: [ShortcutOwnerIssue] = []
    if invalidStoredProfile { issues.append(.invalidStoredProfile) }
    if let storageIssue { issues.append(storageIssue) }
    if pending != nil { issues.append(.uncertainPublication) }
    if let catalogIssue { issues.append(catalogIssue) }
    if let composition, !composition.conflicts.isEmpty {
      issues.append(.conflicts(composition.conflicts))
    }
    return ShortcutOwnerState(
      catalog: catalog, catalogRevision: catalogRevision, profileRevision: profileRevision,
      profile: profile, composition: composition, issues: issues, isBusy: operation != nil,
      hasPendingPublication: pending != nil)
  }
  init(services: ShortcutServices, catalog: [CommandDescriptor], onChange: (() -> Void)? = nil) {
    self.services = services
    self.catalog = catalog
    self.onChange = onChange
  }
  private func begin() throws -> UUID {
    guard operation == nil else { throw ApplicationShortcutError.busy }
    let id = UUID()
    operation = id
    onChange?()
    return id
  }
  private func finish(_ id: UUID) {
    guard operation == id else { return }
    operation = nil
    // Nothing may mutate state after this callback: it can start a new operation/catalog.
    onChange?()
  }
  private func composeCurrent(_ id: UUID) async {
    while operation == id {
      let revision = catalogRevision
      let commands = catalog
      let currentProfile = profile
      let compose = services.compose
      let result = await Task.detached {
        Result { try compose(commands, currentProfile, revision) }
      }.value
      guard operation == id else { return }
      guard catalogRevision == revision else { continue }
      switch result {
      case .success(let value):
        composition = value
        catalogIssue = nil
      case .failure:
        composition = nil
        catalogIssue = .invalidCatalog
      }
      return
    }
  }
  private func validateDraft(_ profile: ShortcutProfile, operation id: UUID) async throws {
    while operation == id {
      let revision = catalogRevision
      let commands = catalog
      let compose = services.compose
      let result = await Task.detached { Result { try compose(commands, profile, revision) } }.value
      guard operation == id else { throw ApplicationShortcutError.busy }
      guard catalogRevision == revision else { continue }
      guard try result.get().conflicts.isEmpty else {
        throw ApplicationShortcutError.conflictingProfile
      }
      return
    }
    throw ApplicationShortcutError.busy
  }
  func load() async throws { try await reload() }
  func reload(discardPending: Bool = false) async throws {
    guard pending == nil || discardPending else {
      throw ApplicationShortcutError.pendingPublication
    }
    let id = try begin()
    let read = services.read
    var failure: Error?
    do {
      let observed = try await Task.detached { try read() }.value
      guard operation == id else { throw ApplicationShortcutError.busy }
      receipt = observed.receipt
      profileRevision = UUID()
      pending = nil
      storageIssue = nil
      switch observed.decoded {
      case .success(let value):
        profile = value
        invalidStoredProfile = false
      case .failure:
        profile = .defaults
        invalidStoredProfile = true
      }
      composition = nil
    } catch {
      failure = error
      storageIssue = .readFailure
    }
    await composeCurrent(id)
    finish(id)
    if let failure { throw failure }
  }
  func apply(_ draft: ShortcutProfile, allowReplacingInvalidStorage: Bool = false) async throws {
    guard pending == nil else { throw ApplicationShortcutError.pendingPublication }
    guard let expected = receipt else { throw ApplicationShortcutError.notLoaded }
    guard !invalidStoredProfile || allowReplacingInvalidStorage else {
      throw ApplicationShortcutError.repairAuthorizationRequired
    }
    let id = try begin()
    var failure: Error?
    do {
      try await validateDraft(draft, operation: id)
      let write = services.write
      let confirmed = try await Task.detached { try write(draft, expected) }.value
      guard operation == id else { throw ApplicationShortcutError.busy }
      receipt = confirmed
      profileRevision = UUID()
      profile = draft
      invalidStoredProfile = false
      storageIssue = nil
      composition = nil
    } catch let error as ShortcutPublicationUncertain {
      pending = Pending(uncertainty: error, profile: draft)
      storageIssue = nil
      failure = error
    } catch {
      storageIssue = .writeFailure
      failure = error
    }
    await composeCurrent(id)
    finish(id)
    if let failure { throw failure }
  }
  func verifyAndRetry() async throws {
    guard let attempted = pending else { throw ApplicationShortcutError.notLoaded }
    let id = try begin()
    let services = services
    var failure: Error?
    do {
      // Validation/readback grants only a temporary receipt for another write, never acknowledgement.
      let temporary = try await Task.detached {
        try services.validate(attempted.uncertainty)
        let observed = try services.read()
        guard observed.receipt.rawBytes == attempted.uncertainty.attemptedBytes,
          try observed.decoded.get() == attempted.profile
        else { throw ApplicationShortcutError.changedPublication }
        // Receipt acquisition must remain inside the original publication's authority.
        // A same-byte replacement parent between the first validation and read must not
        // grant a new receipt permission to overwrite unrelated storage.
        try services.validate(attempted.uncertainty)
        return observed.receipt
      }.value
      guard operation == id else { throw ApplicationShortcutError.busy }
      // Catalog changes may require visible default fallback; they must not prevent confirming the
      // already-published profile. Normal Apply, unlike recovery, refuses conflicting drafts.
      let confirmed = try await Task.detached { try services.write(attempted.profile, temporary) }
        .value
      guard operation == id else { throw ApplicationShortcutError.busy }
      receipt = confirmed
      profileRevision = UUID()
      profile = attempted.profile
      pending = nil
      invalidStoredProfile = false
      storageIssue = nil
      composition = nil
    } catch let error as ShortcutPublicationUncertain {
      pending = Pending(uncertainty: error, profile: attempted.profile)
      storageIssue = nil
      failure = error
    } catch {
      storageIssue = .writeFailure
      failure = error
    }
    await composeCurrent(id)
    finish(id)
    if let failure { throw failure }
  }
  func updateCatalog(_ commands: [CommandDescriptor]) {
    catalog = commands
    catalogRevision = UUID()
    composition = nil
    if operation != nil {
      onChange?()
      return
    }
    let id = UUID()
    operation = id
    onChange?()  // Old menu equivalents/dispatch must be withdrawn immediately.
    Task {
      await composeCurrent(id)
      finish(id)
    }
  }
}
