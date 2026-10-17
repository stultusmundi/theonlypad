// SPDX-License-Identifier: MIT
// Test-only pure existing retained-entry count; no scope or grant is minted.
@MainActor extension ApprovedViewCommitBroker {
  var nestedStringTestRetainedEntryCount: Int {
    invocations.count + decisions.count + barriers.count
      + (pending == nil ? 0 : 1) + (reserved == nil ? 0 : 1)
  }
}
