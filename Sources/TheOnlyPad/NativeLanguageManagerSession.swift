// SPDX-License-Identifier: MIT
import Foundation
import PadCore

struct NativeLanguageManagerCatalogSnapshot {
  let deliveryID: UUID
  let read: NativeLanguageCatalogState
  let mutation: NativeLanguageCatalogMutationState
}
enum NativeLanguageManagerRefreshAdmission {
  case forwarded(NativeLanguageCatalogAdmission)
  case unavailable
}

/// App owns observation; this bounded raw workspace owns no Store, task or catalog receipt.
@MainActor final class NativeLanguageManagerSession {
  private let owner: NativeLanguageCatalogOwner
  private var current: (@MainActor () -> Bool)?
  private(set) var snapshot: NativeLanguageManagerCatalogSnapshot?
  private(set) var isAttached = true
  private var observer: (@MainActor (NativeLanguageManagerCatalogSnapshot) -> Void)?
  private struct Form {
    let handle: NativeLanguageManagerFormHandle
    var baseline: NativeLanguageManagerRawForm?
  }
  private struct Workspace {
    var draftID = UUID()
    var rawEpoch = UUID()
    var viewID = UUID()
    var publicationID: UUID
    var definitions: [NativeLanguageManagerRawDefinition]
    var overrides: [NativeLanguageManagerRawOverride]
    var baseDefinitions: [NativeLanguageManagerRawDefinition]
    var baseOverrides: [NativeLanguageManagerRawOverride]
    var selected: NativeLanguageManagerTarget?
    var form: Form?
    var issues: [NativeLanguageManagerFieldIssue] = []
    var stale = false
    var dirty: Bool { definitions != baseDefinitions || overrides != baseOverrides }
  }
  /// Exists before requestApply can synchronously notify. Only its returned ID can bind outcome.
  private final class Submission {
    let id = UUID()
    let draftID: UUID
    let epoch: UUID
    let base: UUID
    let definitions: [NativeLanguageManagerRawDefinition]
    let overrides: [NativeLanguageManagerRawOverride]
    var operationID: UUID?
    init(_ w: Workspace) {
      draftID = w.draftID
      epoch = w.rawEpoch
      base = w.publicationID
      definitions = w.definitions
      overrides = w.overrides
    }
  }
  private var workspace: Workspace?
  private var submission: Submission?

  var editState: NativeLanguageManagerEditState? {
    guard let w = workspace else { return nil }
    let form = w.form.flatMap { f in
      raw(for: f.handle.target, in: w).map {
        NativeLanguageManagerFormSnapshot(handle: f.handle, raw: $0)
      }
    }
    return .init(
      draftID: w.draftID, rawEpoch: w.rawEpoch, viewID: w.viewID,
      basePublicationID: w.publicationID, definitions: w.definitions, overrides: w.overrides,
      selectedTarget: w.selected, activeForm: form, issues: w.issues, isDirty: w.dirty,
      isStale: w.stale, saveOperationID: submission?.operationID)
  }
  var deletedDefinitions: [NativeLanguageManagerRawDefinition] {
    guard let w = workspace else { return [] }
    return w.baseDefinitions.filter { base in !w.definitions.contains { $0.id == base.id } }
  }
  func isChanged(_ target: NativeLanguageManagerTarget) -> Bool {
    guard let w = workspace else { return false }
    return raw(for: target, in: w)
      != raw(
        for: target,
        definitions: w.baseDefinitions, overrides: w.baseOverrides)
  }
  /// Before the first App delivery there is no draft or receipt-bound presentation to veto.
  /// Detach cannot recreate eligibility: it permanently clears isAttached.
  var isUninstalledPresentation: Bool {
    isAttached && snapshot == nil && current == nil && workspace == nil && submission == nil
  }
  var canDepart: Bool {
    guard let snapshot, isCurrentDelivery(snapshot.deliveryID), case .active = owner.state.lifetime
    else { return false }
    let mutation = owner.mutationState
    guard mutation.activeOperation == nil, mutation.unresolved == nil,
      mutation.preparedQuitID == nil, submission == nil
    else { return false }
    guard let w = workspace else { return true }  // A nonrepresentable catalog stays read-only.
    return !w.dirty && !w.stale && w.form == nil && w.issues.isEmpty
  }
  var onChange: (@MainActor (NativeLanguageManagerCatalogSnapshot) -> Void)? {
    get { observer }
    set {
      guard isAttached else { return }
      let previous = observer
      observer = newValue
      withExtendedLifetime(previous) {}
    }
  }
  init(owner: NativeLanguageCatalogOwner) { self.owner = owner }

  func receive(
    _ snapshot: NativeLanguageManagerCatalogSnapshot,
    isCurrent: @escaping @MainActor () -> Bool
  ) {
    guard isAttached else { return }
    let previous = (self.snapshot, current)
    defer { withExtendedLifetime(previous) {} }
    self.snapshot = snapshot
    current = isCurrent
    guard isCurrentDelivery(snapshot.deliveryID) else { return }
    reconcile(snapshot)
    let callback = observer
    callback?(snapshot)
    // A callback can detach or deliver a successor. No later mutation in this delivery.
  }
  func isCurrentDelivery(_ id: UUID) -> Bool {
    guard isAttached, snapshot?.deliveryID == id, let current else { return false }
    let accepted = current()
    return accepted && isAttached && snapshot?.deliveryID == id
  }
  private func makeWorkspace(_ publication: NativeLanguageCatalogPublication) -> Workspace? {
    let definitions = publication.catalog.definitions.map(NativeLanguageManagerRawValues.raw)
    let overrides = publication.catalog.overrides.map(NativeLanguageManagerRawValues.raw)
    guard NativeLanguageManagerRawValues.fits(definitions: definitions, overrides: overrides) else {
      return nil
    }
    return Workspace(
      publicationID: publication.id, definitions: definitions, overrides: overrides,
      baseDefinitions: definitions, baseOverrides: overrides)
  }
  private func reconcile(_ snapshot: NativeLanguageManagerCatalogSnapshot) {
    guard let publication = snapshot.read.current else { return }
    guard var w = workspace else {
      workspace = makeWorkspace(publication)
      return
    }
    if let intent = submission {
      // Admission notifications precede the real returned operation ID. Preserve them provisionally.
      guard let operation = intent.operationID else {
        w.viewID = UUID()
        workspace = w
        return
      }
      switch snapshot.mutation.lastOutcome {
      case .succeeded(let actual, let receiptID) where actual == operation:
        guard let receiptID, receiptID == publication.id,
          snapshot.mutation.writeReceiptPublicationID == receiptID,
          intent.draftID == w.draftID, intent.base == w.publicationID
        else {
          w.viewID = UUID()
          workspace = w
          return
        }
        // Preserve all newer raw and the exact form. Baseline is the immutable submitted payload.
        w.baseDefinitions = intent.definitions
        w.baseOverrides = intent.overrides
        w.publicationID = receiptID
        w.stale = false
        if var form = w.form {
          form.baseline = raw(
            for: form.handle.target,
            definitions: intent.definitions, overrides: intent.overrides)
          w.form = form
        }
        submission = nil
      case .failed(let actual, _) where actual == operation:
        // Owner retains its actual failed/pending IDs; local raw/base remain untouched.
        submission = nil
      default: break
      }
      if submission != nil {
        w.viewID = UUID()
        workspace = w
        return
      }
    }
    if publication.id != w.publicationID {
      if w.dirty || w.form != nil || w.stale {
        w.stale = true
      } else {
        var fresh = makeWorkspace(publication)
        if let selected = w.selected, let value = fresh {
          if case .builtIn = selected {
            fresh?.selected = selected
          } else if raw(for: selected, in: value) != nil {
            fresh?.selected = selected
          }
        }
        workspace = fresh
        return
      }
    }
    w.viewID = UUID()
    workspace = w
  }
  /// Revalidates after the current-delivery callback, then checks the ACTUAL owner reservation.
  private func refusal(draft: UUID? = nil, epoch: UUID? = nil) -> NativeLanguageManagerEditRefusal?
  {
    guard isAttached else { return .detached }
    // Reservation has priority even for stale UI handles in a synchronous prepare notification.
    if let id = owner.mutationState.preparedQuitID { return .catalog(.quitPrepared(quitID: id)) }
    guard let snapshot, isCurrentDelivery(snapshot.deliveryID), case .active = owner.state.lifetime
    else { return .unavailable }
    if let id = owner.mutationState.preparedQuitID { return .catalog(.quitPrepared(quitID: id)) }
    guard let w = workspace else { return .unavailable }
    if let draft, draft != w.draftID { return .wrongDraft }
    if let epoch, epoch != w.rawEpoch { return .wrongEpoch }
    return nil
  }
  private func raw(for target: NativeLanguageManagerTarget, in w: Workspace)
    -> NativeLanguageManagerRawForm?
  {
    raw(for: target, definitions: w.definitions, overrides: w.overrides)
  }
  private func raw(
    for target: NativeLanguageManagerTarget,
    definitions: [NativeLanguageManagerRawDefinition], overrides: [NativeLanguageManagerRawOverride]
  )
    -> NativeLanguageManagerRawForm?
  {
    switch target {
    case .definition(let id): return definitions.first { $0.id == id }.map { .definition($0) }
    case .builtIn(let language):
      return overrides.first { $0.language == language }.map { .builtIn($0) }
    }
  }
  private func publish(_ w: Workspace, payloadChanged: Bool) {
    var w = w
    if payloadChanged {
      w.rawEpoch = UUID()
      w.issues = []
    }
    w.viewID = UUID()
    workspace = w
    guard let snapshot, isCurrentDelivery(snapshot.deliveryID) else { return }
    let callback = observer
    callback?(snapshot)
    // Never write local state after this callout.
  }
  private func formRefusal(_ handle: NativeLanguageManagerFormHandle)
    -> NativeLanguageManagerEditRefusal?
  {
    if let refusal = refusal() { return refusal }
    guard workspace?.form?.handle === handle else { return .unavailable }
    return nil
  }
  func beginNewDefinition() -> NativeLanguageManagerFormAdmission {
    if let r = refusal() { return .refused(r) }
    guard var w = workspace else { return .refused(.unavailable) }
    guard w.form == nil else { return .refused(.formInProgress) }
    let value = NativeLanguageManagerRawDefinition(
      id: UUID(), name: "New Language",
      extensionsText: "", keywordsText: "", lineEnabled: false, lineText: "",
      blockEnabled: false, blockOpening: "", blockClosing: "", quotes: [],
      highlightDecimalNumbers: true, indentationKind: .legacy, widthText: "")
    w.definitions.append(value)
    guard NativeLanguageManagerRawValues.fits(definitions: w.definitions, overrides: w.overrides)
    else { return .refused(.boundExceeded) }
    let handle = NativeLanguageManagerFormHandle(id: UUID(), target: .definition(value.id))
    w.form = Form(handle: handle, baseline: nil)
    w.selected = handle.target
    publish(w, payloadChanged: true)
    guard isAttached, workspace?.form?.handle === handle else { return .refused(.unavailable) }
    return .opened(handle)
  }
  func beginEdit(target: NativeLanguageManagerTarget, expectedDraftID: UUID, expectedEpoch: UUID)
    -> NativeLanguageManagerFormAdmission
  {
    if let r = refusal(draft: expectedDraftID, epoch: expectedEpoch) { return .refused(r) }
    guard var w = workspace else { return .refused(.unavailable) }
    guard w.form == nil else { return .refused(.formInProgress) }
    let baseline = raw(for: target, in: w)
    var changed = false
    if baseline == nil {
      guard case .builtIn(let language) = target else { return .refused(.unavailable) }
      w.overrides.append(NativeLanguageManagerRawValues.inherited(language))
      changed = true
      guard NativeLanguageManagerRawValues.fits(definitions: w.definitions, overrides: w.overrides)
      else { return .refused(.boundExceeded) }
    }
    let handle = NativeLanguageManagerFormHandle(id: UUID(), target: target)
    w.form = Form(handle: handle, baseline: baseline)
    w.selected = target
    publish(w, payloadChanged: changed)
    guard isAttached, workspace?.form?.handle === handle else { return .refused(.unavailable) }
    return .opened(handle)
  }
  func updateForm(handle: NativeLanguageManagerFormHandle, raw: NativeLanguageManagerRawForm)
    -> NativeLanguageManagerEditAdmission
  {
    if let r = formRefusal(handle) { return .refused(r) }
    guard var w = workspace, raw.target == handle.target else { return .refused(.unavailable) }
    let previous = self.raw(for: handle.target, in: w)
    replace(raw, target: handle.target, in: &w)
    guard NativeLanguageManagerRawValues.fits(definitions: w.definitions, overrides: w.overrides)
    else { return .refused(.boundExceeded) }
    if previous != raw { publish(w, payloadChanged: true) }
    return .accepted
  }
  private func replace(
    _ value: NativeLanguageManagerRawForm?, target: NativeLanguageManagerTarget,
    in w: inout Workspace
  ) {
    switch target {
    case .definition(let id):
      let index = w.definitions.firstIndex { $0.id == id }
      if case .definition(let d)? = value {
        if let index { w.definitions[index] = d } else { w.definitions.append(d) }
      } else if let index {
        w.definitions.remove(at: index)
      }
    case .builtIn(let language):
      let index = w.overrides.firstIndex { $0.language == language }
      if case .builtIn(let o)? = value {
        if let index { w.overrides[index] = o } else { w.overrides.append(o) }
      } else if let index {
        w.overrides.remove(at: index)
      }
    }
  }
  func finishForm(handle: NativeLanguageManagerFormHandle) -> NativeLanguageManagerEditAdmission {
    if let r = formRefusal(handle) { return .refused(r) }
    guard var w = workspace, let raw = raw(for: handle.target, in: w) else {
      return .refused(.unavailable)
    }
    let issues = NativeLanguageManagerRawValues.issues(raw)
    guard issues.isEmpty else {
      w.issues = issues
      publish(w, payloadChanged: false)
      return .refused(.invalid(issues))
    }
    w.form = nil
    w.issues = []
    publish(w, payloadChanged: false)
    return .accepted
  }
  func discardFormChanges(handle: NativeLanguageManagerFormHandle)
    -> NativeLanguageManagerEditAdmission
  {
    if let r = formRefusal(handle) { return .refused(r) }
    guard var w = workspace, let form = w.form else { return .refused(.unavailable) }
    let previous = raw(for: handle.target, in: w)
    replace(form.baseline, target: handle.target, in: &w)
    guard NativeLanguageManagerRawValues.fits(definitions: w.definitions, overrides: w.overrides)
    else { return .refused(.boundExceeded) }
    w.form = nil
    w.issues = []
    publish(w, payloadChanged: previous != form.baseline)
    return .accepted
  }
  func stageDelete(profileID: UUID, expectedDraftID: UUID, expectedEpoch: UUID)
    -> NativeLanguageManagerEditAdmission
  {
    if let r = refusal(draft: expectedDraftID, epoch: expectedEpoch) { return .refused(r) }
    guard var w = workspace else { return .refused(.unavailable) }
    guard w.form == nil else { return .refused(.formInProgress) }
    guard let index = w.definitions.firstIndex(where: { $0.id == profileID }) else {
      return .refused(.unavailable)
    }
    w.definitions.remove(at: index)
    w.selected = .definition(profileID)  // selected tombstone
    publish(w, payloadChanged: true)
    return .accepted
  }
  func revertChange(target: NativeLanguageManagerTarget, expectedDraftID: UUID, expectedEpoch: UUID)
    -> NativeLanguageManagerEditAdmission
  {
    if let r = refusal(draft: expectedDraftID, epoch: expectedEpoch) { return .refused(r) }
    guard var w = workspace else { return .refused(.unavailable) }
    guard w.form == nil else { return .refused(.formInProgress) }
    let old = raw(for: target, in: w)
    let value = raw(for: target, definitions: w.baseDefinitions, overrides: w.baseOverrides)
    replace(value, target: target, in: &w)
    guard NativeLanguageManagerRawValues.fits(definitions: w.definitions, overrides: w.overrides)
    else { return .refused(.boundExceeded) }
    // Restore base ordering for a deleted definition without disturbing added entries.
    if case .definition(let id) = target, value != nil,
      let baseIndex = w.baseDefinitions.firstIndex(where: { $0.id == id }),
      let currentIndex = w.definitions.firstIndex(where: { $0.id == id })
    {
      let d = w.definitions.remove(at: currentIndex)
      let followingIDs = Set(w.baseDefinitions.dropFirst(baseIndex + 1).map(\.id))
      let insertion =
        w.definitions.firstIndex { followingIDs.contains($0.id) } ?? w.definitions.count
      w.definitions.insert(d, at: insertion)
    }
    w.selected = target
    w.issues = []
    publish(w, payloadChanged: old != value)
    return .accepted
  }
  func discardDraft(expectedDraftID: UUID, expectedEpoch: UUID)
    -> NativeLanguageManagerEditAdmission
  {
    if let r = refusal(draft: expectedDraftID, epoch: expectedEpoch) { return .refused(r) }
    guard workspace?.form == nil else { return .refused(.formInProgress) }
    guard submission == nil, owner.mutationState.activeOperation == nil else {
      return .refused(.busy)
    }
    if let r = unresolvedRefusal() { return .refused(r) }
    guard let publication = owner.state.current, let fresh = makeWorkspace(publication)
    else { return .refused(.unavailable) }
    publish(fresh, payloadChanged: false)
    return .accepted
  }
  private func unresolvedRefusal() -> NativeLanguageManagerEditRefusal? {
    switch owner.mutationState.unresolved {
    case .failedAttempt(let id, _, _): return .catalog(.unresolvedAttempt(attemptID: id))
    case .pending(_, let id, _, _): return .catalog(.unresolvedPending(recoveryID: id))
    case nil: return nil
    }
  }
  func requestSave(expectedDraftID: UUID, expectedEpoch: UUID) -> NativeLanguageManagerSaveAdmission
  {
    if let r = refusal(draft: expectedDraftID, epoch: expectedEpoch) { return .refused(r) }
    guard var w = workspace else { return .refused(.unavailable) }
    guard !w.stale, owner.state.current?.id == w.publicationID else { return .refused(.staleBase) }
    guard submission == nil, owner.mutationState.activeOperation == nil else {
      return .refused(.busy)
    }
    if let r = unresolvedRefusal() { return .refused(r) }
    guard owner.mutationState.writeReceiptPublicationID == w.publicationID else {
      return .refused(.noWriteReceipt)
    }
    let draft: NativeLanguageCatalogDraft
    switch NativeLanguageManagerRawValues.validated(
      definitions: w.definitions, overrides: w.overrides)
    {
    case .failure(let error):
      w.issues = error.issues
      publish(w, payloadChanged: false)
      return .refused(.invalid(error.issues))
    case .success(let validated): draft = validated
    }
    let intent = Submission(w)
    submission = intent  // BEFORE the owner's synchronous admission notification.
    let admission = owner.requestApply(draft, expectedPublication: .current(w.publicationID))
    // The callback may have detached the session. Bind only this retained exact intent.
    switch admission {
    case .started(let actual):
      if submission === intent {
        intent.operationID = actual
        if let snapshot, isCurrentDelivery(snapshot.deliveryID), submission === intent {
          reconcile(snapshot)
          if let snapshot = self.snapshot, isCurrentDelivery(snapshot.deliveryID) {
            let callback = observer
            callback?(snapshot)
          }
        }
      }
      return .started(actual)
    case .refused(let reason):
      if submission === intent {
        submission = nil
        if let snapshot, isCurrentDelivery(snapshot.deliveryID) {
          reconcile(snapshot)
          let callback = observer
          callback?(snapshot)
        }
      }
      return .refused(.catalog(reason))
    }
  }
  func requestRefresh() -> NativeLanguageManagerRefreshAdmission {
    guard let snapshot, isCurrentDelivery(snapshot.deliveryID), case .active = owner.state.lifetime
    else { return .unavailable }
    if let w = workspace, w.dirty || w.stale || w.form != nil { return .unavailable }
    guard submission == nil else { return .unavailable }
    let mutation = owner.mutationState
    guard mutation.activeOperation == nil, mutation.preparedQuitID == nil,
      mutation.unresolved == nil
    else { return .unavailable }
    return .forwarded(owner.requestLoad())
  }
  /// Selection is view state; it never changes an already issued form target.
  func select(_ target: NativeLanguageManagerTarget?) {
    guard let snapshot, isCurrentDelivery(snapshot.deliveryID), var w = workspace,
      w.selected != target
    else { return }
    w.selected = target
    publish(w, payloadChanged: false)
  }
  func detach() {
    guard isAttached else { return }
    let previous = (snapshot, current, observer)
    isAttached = false
    snapshot = nil
    current = nil
    observer = nil
    // Keep raw and submitted intent retained; detachment is neither Save nor acknowledgement.
    withExtendedLifetime(previous) {}
  }
}

@MainActor final class NativeLanguageManagerFormHandle {
  let id: UUID
  let target: NativeLanguageManagerTarget
  fileprivate init(id: UUID, target: NativeLanguageManagerTarget) {
    self.id = id
    self.target = target
  }
}
