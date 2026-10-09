package enum SearchAdmissionJoinedCallerRefusal: Sendable, Equatable {
  case unsupportedDriver, legacyModeSelected, synchronousCallbackActive
}

package enum SearchAdmissionJoinedShutdownResult: Sendable, Equatable {
  case callerRefused(SearchAdmissionJoinedCallerRefusal)
  case observed(SearchAdmissionJoinedShutdownObservation)
}

/// Immutable parent diagnostics and separately refreshed local ownership facts.
package struct SearchAdmissionJoinedShutdownObservation: Sendable, Equatable {
  package let parent: SearchParentJoinedShutdownResult
  package let driverSettlement: SearchParentWireSettlement
  package let retainedActiveJobs: Int
  package let retainedLeases: Int
  package let activeCharge: UInt64
  package let retainedCharge: UInt64
  package let reservedRetainedCharge: UInt64
}
