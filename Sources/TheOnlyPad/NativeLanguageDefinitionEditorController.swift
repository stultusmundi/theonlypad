// SPDX-License-Identifier: MIT
import AppKit
import PadCore

@MainActor private final class LanguageDefinitionWindow: NSPanel {
  var beforeClose: (@MainActor () -> Void)?
  override func close() { beforeClose?() }
  override func cancelOperation(_ sender: Any?) { beforeClose?() }
  fileprivate func commitClose() {
    beforeClose = nil
    super.close()
  }
}

@MainActor private final class LanguageQuoteControls {
  let id: UUID
  let opening = NSTextField()
  let closing = NSTextField()
  let escape = NSTextField()
  let escapeEnabled = NSButton(checkboxWithTitle: "Escape", target: nil, action: nil)
  let multiline = NSButton(checkboxWithTitle: "Multiline", target: nil, action: nil)
  let remove = NSButton(title: "Remove quote", target: nil, action: nil)
  init(id: UUID) { self.id = id }
}

/// Exact-target, modeless child. Its controls never obtain catalog or document undo authority.
@MainActor
final class NativeLanguageDefinitionEditorController: NSWindowController,
  NSTextFieldDelegate, NSTextViewDelegate
{
  private let handle: NativeLanguageManagerFormHandle
  private let session: NativeLanguageManagerSession
  private let nameField = NSTextField()
  private let extensionsTextView = NSTextView()
  private let keywordsTextView = NSTextView()
  private let lineToggle = NSButton(checkboxWithTitle: "Line comment", target: nil, action: nil)
  private let lineField = NSTextField()
  private let blockToggle = NSButton(checkboxWithTitle: "Block comment", target: nil, action: nil)
  private let blockOpeningField = NSTextField()
  private let blockClosingField = NSTextField()
  private let decimalToggle = NSButton(
    checkboxWithTitle: "Decimal numbers", target: nil, action: nil)
  private let indentationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let widthField = NSTextField()
  private let doneButton = NSButton(title: "Done", target: nil, action: nil)
  private let discardButton = NSButton(title: "Discard Form Changes", target: nil, action: nil)
  private let lineKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let blockKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let quoteStack = NSStackView()
  private let addQuoteButton = NSButton(title: "Add Quote", target: nil, action: nil)
  private let message = NSTextField(wrappingLabelWithString: "")
  private var quotes: [LanguageQuoteControls] = []
  private var renderedRaw: NativeLanguageManagerRawForm?
  private var rendering = false
  private var submitting = false
  private var pendingInput = false
  // Native callbacks can arrive during a synchronous session publication. This fences newer
  // unsubmitted control input independently of the session's admitted raw epoch.
  private var nativeInputEpoch = UUID()
  private var retired = false

  init(handle: NativeLanguageManagerFormHandle, session: NativeLanguageManagerSession) {
    self.handle = handle
    self.session = session
    let panel = LanguageDefinitionWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: panel)
    panel.title = "Edit Language Definition"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 640, height: 650)
    panel.beforeClose = { [weak self] in self?.explainCloseVeto() }
    let content = NSView()
    panel.contentView = content
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
    ])
    func row(_ title: String, _ field: NSView) {
      let label = NSTextField(labelWithString: title)
      let line = NSStackView(views: [label, field])
      line.spacing = 8
      stack.addArrangedSubview(line)
      line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      label.widthAnchor.constraint(equalToConstant: 130).isActive = true
      field.setAccessibilityLabel(title)
    }
    row("Name / language", nameField)
    row("Extensions (one/line)", Self.scroll(extensionsTextView))
    row("Keywords (one/line)", Self.scroll(keywordsTextView))
    for popup in [lineKindPopup, blockKindPopup] {
      popup.addItems(withTitles: ["Inherit", "Disabled", "Literal"])
      popup.target = self
      popup.action = #selector(changed(_:))
    }
    row("Line policy", lineKindPopup)
    row("Line comment", NSStackView(views: [lineToggle, lineField]))
    row("Block policy", blockKindPopup)
    row("Block comment", NSStackView(views: [blockToggle, blockOpeningField, blockClosingField]))
    stack.addArrangedSubview(decimalToggle)
    quoteStack.orientation = .vertical
    quoteStack.alignment = .leading
    quoteStack.spacing = 6
    stack.addArrangedSubview(quoteStack)
    quoteStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.addArrangedSubview(addQuoteButton)
    indentationPopup.addItems(withTitles: ["Legacy", "Spaces", "Tabs"])
    row("Indentation", NSStackView(views: [indentationPopup, widthField]))
    stack.addArrangedSubview(message)
    message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.addArrangedSubview(NSStackView(views: [doneButton, discardButton]))
    for field in [nameField, lineField, blockOpeningField, blockClosingField, widthField] {
      field.delegate = self
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
    }
    for text in [extensionsTextView, keywordsTextView] { text.delegate = self }
    for button in [lineToggle, blockToggle, decimalToggle] {
      button.target = self
      button.action = #selector(changed(_:))
    }
    indentationPopup.target = self
    indentationPopup.action = #selector(changed(_:))
    addQuoteButton.target = self
    addQuoteButton.action = #selector(addQuote(_:))
    doneButton.target = self
    doneButton.action = #selector(done(_:))
    discardButton.target = self
    discardButton.action = #selector(discard(_:))
    doneButton.keyEquivalent = "\r"
    for (view, id) in [
      (nameField as NSView, "name"), (extensionsTextView, "extensions"),
      (keywordsTextView, "keywords"), (lineField, "line"), (blockOpeningField, "block.opening"),
      (blockClosingField, "block.closing"), (widthField, "width"), (doneButton, "done"),
      (discardButton, "discard"),
    ] {
      view.setAccessibilityIdentifier("languages.editor." + id)
    }
  }
  required init?(coder: NSCoder) { nil }
  private static func scroll(_ text: NSTextView) -> NSScrollView {
    text.isRichText = false
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.textContainer?.widthTracksTextView = true
    // Undo belongs to this new text view / panel's field editor, never an editor document.
    text.allowsUndo = true
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 60))
    text.frame = scroll.contentView.bounds
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.heightAnchor.constraint(equalToConstant: 60).isActive = true
    return scroll
  }
  func matches(_ handle: NativeLanguageManagerFormHandle) -> Bool {
    self.handle === handle && !retired
  }
  private var isCurrent: Bool {
    guard !retired, session.isAttached, let state = session.editState,
      state.activeForm?.handle === handle, let snapshot = session.snapshot
    else { return false }
    return session.isCurrentDelivery(snapshot.deliveryID)
      && session.editState?.activeForm?.handle === handle && !retired
  }
  func render(_ raw: NativeLanguageManagerRawForm) {
    guard isCurrent, raw.target == handle.target, !rendering, !submitting,
      let state = session.editState, let delivery = session.snapshot?.deliveryID
    else { return }
    // Rejected field-editor input is retained until an explicit successful update or discard.
    guard !pendingInput else { return }
    let view = state.viewID
    func live() -> Bool {
      isCurrent && session.snapshot?.deliveryID == delivery && session.editState?.viewID == view
    }
    func step(_ body: () -> Void) -> Bool {
      guard live() else { return false }
      body()
      return live()
    }
    rendering = true
    defer {
      rendering = false
      // A setter can synchronously deliver a newer frame while this frame was rendering.
      if !retired, !pendingInput, let latest = session.editState,
        latest.viewID != view, let form = latest.activeForm, form.handle === handle
      {
        render(form.raw)
      }
    }
    renderedRaw = raw
    func field(_ control: NSTextField, _ value: String) -> Bool {
      step {
        if !control.stringValue.utf16.elementsEqual(value.utf16) { control.stringValue = value }
      }
    }
    func text(_ control: NSTextView, _ value: String) -> Bool {
      step { if !control.string.utf16.elementsEqual(value.utf16) { control.string = value } }
    }
    let definition: Bool
    switch raw {
    case .definition(let d):
      definition = true
      guard field(nameField, d.name), text(extensionsTextView, d.extensionsText),
        text(keywordsTextView, d.keywordsText),
        step({ lineToggle.state = d.lineEnabled ? .on : .off }),
        step({ blockToggle.state = d.blockEnabled ? .on : .off }),
        field(lineField, d.lineText), field(blockOpeningField, d.blockOpening),
        field(blockClosingField, d.blockClosing),
        step({ decimalToggle.state = d.highlightDecimalNumbers ? .on : .off }),
        step({ indentationPopup.selectItem(at: Self.index(d.indentationKind)) }),
        field(widthField, d.widthText),
        renderQuotes(d.quotes, live: live)
      else { return }
    case .builtIn(let o):
      definition = false
      guard field(nameField, o.language.rawValue),
        step({ lineKindPopup.selectItem(at: Self.index(o.lineKind)) }),
        step({ blockKindPopup.selectItem(at: Self.index(o.blockKind)) }),
        field(lineField, o.lineText), field(blockOpeningField, o.blockOpening),
        field(blockClosingField, o.blockClosing),
        step({ indentationPopup.selectItem(at: Self.index(o.indentationKind)) }),
        field(widthField, o.widthText)
      else { return }
    }
    guard step({ nameField.isEditable = definition }),
      step({ extensionsTextView.enclosingScrollView?.isHidden = !definition }),
      step({ keywordsTextView.enclosingScrollView?.isHidden = !definition }),
      step({ lineToggle.isHidden = !definition }), step({ blockToggle.isHidden = !definition }),
      step({ lineKindPopup.isHidden = definition }), step({ blockKindPopup.isHidden = definition }),
      step({ quoteStack.isHidden = !definition }), step({ addQuoteButton.isHidden = !definition }),
      step({ decimalToggle.isHidden = !definition })
    else { return }
    _ = step {
      message.stringValue =
        state.issues.isEmpty
        ? "" : "Invalid fields remain unchanged. Correct them before Done or Save."
    }
  }
  private static func index(_ kind: NativeLanguageManagerIndentationKind) -> Int {
    switch kind {
    case .legacy: return 0
    case .spaces: return 1
    case .tabs: return 2
    }
  }
  private static func index(_ kind: NativeLanguageManagerCommentKind) -> Int {
    switch kind {
    case .inherit: return 0
    case .disabled: return 1
    case .literal: return 2
    }
  }
  private func renderQuotes(_ values: [NativeLanguageManagerRawQuote], live: () -> Bool) -> Bool {
    func step(_ body: () -> Void) -> Bool {
      guard live() else { return false }
      body()
      return live()
    }
    if quotes.map(\.id) != values.map(\.rowID) {
      for row in quoteStack.arrangedSubviews {
        guard step({ quoteStack.removeArrangedSubview(row) }), step({ row.removeFromSuperview() })
        else { return false }
      }
      guard live() else { return false }
      quotes = values.map { LanguageQuoteControls(id: $0.rowID) }
      guard live() else { return false }
      for (index, q) in quotes.enumerated() {
        for field in [q.opening, q.closing, q.escape] {
          guard step({ field.delegate = self }),
            step({ field.widthAnchor.constraint(equalToConstant: 70).isActive = true })
          else { return false }
        }
        for b in [q.escapeEnabled, q.multiline] {
          guard step({ b.target = self }), step({ b.action = #selector(changed(_:)) }) else {
            return false
          }
        }
        guard step({ q.remove.tag = index }), step({ q.remove.target = self }),
          step({ q.remove.action = #selector(removeQuote(_:)) })
        else { return false }
        let row = NSStackView(views: [
          q.opening, q.closing, q.escapeEnabled, q.escape, q.multiline, q.remove,
        ])
        guard step({ quoteStack.addArrangedSubview(row) }) else { return false }
      }
    }
    for (q, raw) in zip(quotes, values) {
      guard step({ q.opening.stringValue = raw.opening }),
        step({ q.closing.stringValue = raw.closing }),
        step({ q.escape.stringValue = raw.escapeText }),
        step({ q.escapeEnabled.state = raw.escapeEnabled ? .on : .off }),
        step({ q.multiline.state = raw.multiline ? .on : .off })
      else { return false }
    }
    return step { addQuoteButton.isEnabled = values.count < 4 }
  }
  private func rawFromControls() -> NativeLanguageManagerRawForm? {
    guard let renderedRaw else { return nil }
    let kind: NativeLanguageManagerIndentationKind
    switch indentationPopup.indexOfSelectedItem {
    case 1: kind = .spaces
    case 2: kind = .tabs
    default: kind = .legacy
    }
    switch renderedRaw {
    case .definition(let previous):
      return .definition(
        .init(
          id: previous.id, name: nameField.stringValue,
          extensionsText: extensionsTextView.string, keywordsText: keywordsTextView.string,
          lineEnabled: lineToggle.state == .on, lineText: lineField.stringValue,
          blockEnabled: blockToggle.state == .on, blockOpening: blockOpeningField.stringValue,
          blockClosing: blockClosingField.stringValue,
          quotes: quotes.map {
            .init(
              rowID: $0.id, opening: $0.opening.stringValue,
              closing: $0.closing.stringValue, escapeEnabled: $0.escapeEnabled.state == .on,
              escapeText: $0.escape.stringValue, multiline: $0.multiline.state == .on)
          },
          highlightDecimalNumbers: decimalToggle.state == .on, indentationKind: kind,
          widthText: widthField.stringValue))
    case .builtIn(let previous):
      func comment(_ p: NSPopUpButton) -> NativeLanguageManagerCommentKind {
        switch p.indexOfSelectedItem {
        case 1: return .disabled
        case 2: return .literal
        default: return .inherit
        }
      }
      return .builtIn(
        .init(
          language: previous.language, lineKind: comment(lineKindPopup),
          lineText: lineField.stringValue,
          blockKind: comment(blockKindPopup), blockOpening: blockOpeningField.stringValue,
          blockClosing: blockClosingField.stringValue, indentationKind: kind,
          widthText: widthField.stringValue))
    }
  }
  @discardableResult private func submitControls() -> Bool {
    guard !rendering, !submitting, isCurrent, let before = session.editState,
      let raw = rawFromControls()
    else { return false }
    let inputEpoch = nativeInputEpoch
    submitting = true
    let outcome = session.updateForm(handle: handle, raw: raw)
    submitting = false
    guard isCurrent, let latest = session.editState, latest.draftID == before.draftID,
      let form = latest.activeForm, form.handle === handle
    else { return false }
    // A newer native event is still pending; neither an accepted A nor a model successor B
    // may clear it or overwrite those controls. A later deliberate flush can submit it.
    guard nativeInputEpoch == inputEpoch else { return false }
    switch outcome {
    case .accepted:
      // updateForm can synchronously admit successor B for the SAME handle while renders
      // are suppressed. Render the actual latest admitted raw, never the submitted A.
      let delivery = session.snapshot?.deliveryID
      guard session.editState?.viewID == latest.viewID,
        session.editState?.rawEpoch == latest.rawEpoch, isCurrent,
        session.snapshot?.deliveryID == delivery, nativeInputEpoch == inputEpoch
      else { return false }
      pendingInput = false
      render(form.raw)
      // Rendering itself can call out. Only a fully current admitted/native frame may
      // continue through Done/Save; stale controls must never become another submission.
      guard isCurrent, let settled = session.editState, settled.draftID == before.draftID,
        let settledForm = settled.activeForm, settledForm.handle === handle,
        nativeInputEpoch == inputEpoch, !pendingInput,
        renderedRaw == settledForm.raw, rawFromControls() == settledForm.raw,
        session.editState?.viewID == settled.viewID,
        session.editState?.rawEpoch == settled.rawEpoch
      else { return false }
      return true
    case .refused:
      pendingInput = true
      message.stringValue = "Input is retained. Editing is paused or a raw limit was exceeded."
      return false
    }
  }
  private func receiveNativeInput() {
    guard !rendering else { return }
    nativeInputEpoch = UUID()
    pendingInput = true
    _ = submitControls()
  }
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      [nameField, lineField, blockOpeningField, blockClosingField, widthField].contains(where: {
        $0 === field
      })
        || quotes.contains(where: {
          $0.opening === field || $0.closing === field || $0.escape === field
        })
    else { return }
    receiveNativeInput()
  }
  func textDidChange(_ notification: Notification) {
    guard let view = notification.object as? NSTextView,
      view === extensionsTextView || view === keywordsTextView
    else { return }
    receiveNativeInput()
  }
  @objc private func changed(_ sender: Any?) { receiveNativeInput() }
  @objc private func addQuote(_ sender: NSButton) {
    guard flush(), isCurrent, case .definition(var raw)? = session.editState?.activeForm?.raw,
      raw.quotes.count < 4
    else { return }
    raw.quotes.append(
      .init(
        rowID: UUID(), opening: "\"", closing: "\"", escapeEnabled: false, escapeText: "",
        multiline: false))
    _ = session.updateForm(handle: handle, raw: .definition(raw))
  }
  @objc private func removeQuote(_ sender: NSButton) {
    guard let row = quotes.first(where: { $0.remove === sender }), flush(), isCurrent,
      case .definition(var raw)? = session.editState?.activeForm?.raw,
      let index = raw.quotes.firstIndex(where: { $0.rowID == row.id })
    else { return }
    raw.quotes.remove(at: index)
    _ = session.updateForm(handle: handle, raw: .definition(raw))
  }
  /// Native resignation may synchronously replace the form or begin an actual App quit.
  func flush() -> Bool {
    guard isCurrent, let window, let before = session.editState else { return false }
    if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
    guard window.makeFirstResponder(nil), isCurrent,
      session.editState?.draftID == before.draftID, session.editState?.rawEpoch == before.rawEpoch,
      session.editState?.activeForm?.handle === handle
    else { return false }
    return submitControls()
  }
  @objc private func done(_ sender: NSButton) {
    guard flush(), isCurrent else { return }
    if case .refused = session.finishForm(handle: handle), isCurrent {
      message.stringValue =
        "Correct invalid fields, then choose Done or Save. Raw input is retained."
    }
  }
  @objc private func discard(_ sender: NSButton) {
    // Explicit discard can abandon rejected raw text, but never an active marked composition.
    guard isCurrent, let window, let before = session.editState else { return }
    if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return }
    guard window.makeFirstResponder(nil), isCurrent, session.editState?.draftID == before.draftID,
      session.editState?.rawEpoch == before.rawEpoch
    else { return }
    _ = session.discardFormChanges(handle: handle)
  }
  override func close() { explainCloseVeto() }
  override func cancelOperation(_ sender: Any?) { explainCloseVeto() }
  private func explainCloseVeto() {
    guard isCurrent else { return }
    message.stringValue = "Choose Done or Discard Form Changes before closing this editor."
  }
  func retire() {
    guard !retired else { return }
    retired = true
    // Retire all native callbacks before child/window notification callouts.
    for field in [nameField, lineField, blockOpeningField, blockClosingField, widthField] {
      field.delegate = nil
    }
    for text in [extensionsTextView, keywordsTextView] { text.delegate = nil }
    for q in quotes { for field in [q.opening, q.closing, q.escape] { field.delegate = nil } }
    if let child = window { child.parent?.removeChildWindow(child) }
    (window as? LanguageDefinitionWindow)?.commitClose()
  }
}
