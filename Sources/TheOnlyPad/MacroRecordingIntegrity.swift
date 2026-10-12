// SPDX-License-Identifier: MIT
// Task2A adapter values. Native-origin grants and notice delivery remain held.
import Foundation
import PadCore

enum MacroRecordingGap: UInt8, Equatable {
  case unsupportedCharacterMutation, explicitCommitRefused, primitiveSequenceExhausted
  case recorderStateSerialExhausted, externalRecorderWrite, contextUnavailable
}
struct MacroRecordingIntegrity {
  let epoch: UUID
  let documentID: UUID
  var active: Bool
  var firstReason: MacroRecordingGap?
  var noticePending = false
}
enum MacroCompatibilityPhase {
  case none, identityNil, identityNonNil, commandsAfterNil, commandsAfterNonNil
}
struct MacroBindingLease: Equatable {
  let controllerID: ObjectIdentifier
  let documentObjectID: ObjectIdentifier
  let documentID: UUID
  let storageID: ObjectIdentifier
  let ownershipGeneration: UUID
  let endpointID: UUID?
  let assignment: DocumentAssignment?
  let serial: UInt64
  var paneIDs: [UUID]
}
struct MacroPrimitiveCapture {
  let lease: MacroBindingLease
  let epoch: UUID?
}
struct MacroPreparedReplacement {
  let replacement: String
  let replacementUTF16Count: Int
  let beforeUTF16Count: Int
  let changedCharacters: Bool
  let primitive: MacroContextPrimitiveState
}
struct MacroExplicitSeed {
  let lease: MacroBindingLease
  let identity: MacroContextIdentity
  let primitive: MacroContextPrimitiveState
  let contract: MacroContextPrimitiveContract
  let commands: [MacroCommand]
  let units: Int
  let command: MacroCommand
  let preparedReplacement: MacroPreparedReplacement
}
struct MacroExplicitDelivery {
  let seed: MacroExplicitSeed
  let permit: MacroContextPermit
  let capture: MacroPrimitiveCapture
}
struct MacroRecordingSaveAttempt {
  let id: UUID
  let epoch: UUID
  let documentID: UUID
  let serial: UInt64
  let commands: [MacroCommand]
  let units: Int
}

// Tiny forward String prototype values. No native-origin grant is introduced.
enum ControlledStringInsertionResult {
  case unhandled, handledRefused, handledCommitted
}

// Transient prepared facts; never retained by the value-only commit context.
// The weak owner is an authentic existing binding capture, not permission.
struct MacroControlledCharacterWrite {
  let storageID: ObjectIdentifier
  let range: NSRange
  let replacement: MacroPreparedReplacement
  weak var owner: EditorWindowController?
  let capture: MacroPrimitiveCapture?
}
