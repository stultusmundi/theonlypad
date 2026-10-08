/// Conservative logical content reservations, not measured allocation or resident memory.
/// Each controller owns its own ledger; these allowances do not bound caller contexts or aliases.
package struct SearchAdmissionProductionAccounting: SearchAdmissionAccounting, Sendable {
  package init() {}

  package var activeLimit: UInt64 { 1_610_612_736 }
  package var retainedLimit: UInt64 { 1_342_177_280 }
  package var resident: UInt64 { 1_048_576 }

  package func charge(for descriptor: SearchAdmissionDescriptor) throws -> SearchAdmissionCharge {
    let textLimit = try dimension(
      descriptor.limits.maxTextUTF16, maximum: searchWireGlobalMaximumUTF16)
    let input = try dimension(
      descriptor.estimatedInputUTF16, maximum: searchWireGlobalMaximumUTF16)
    guard input <= textLimit else { throw SearchAdmissionFailure.invalidDescriptor }
    let outputLimit = try dimension(
      descriptor.limits.maxOutputUTF16, maximum: searchWireGlobalMaximumUTF16)
    let matches = try dimension(
      descriptor.limits.maxMatches, maximum: searchWireGlobalMaximumMatches)
    let query = try blobUnits(descriptor.query.pattern)

    let output: UInt64
    let template: UInt64
    switch descriptor.operation {
    case .find:
      output = 0
      template = 0
    case .replace(let text):
      output = outputLimit
      template = try blobUnits(text)
    }

    // The real boundary bitmap includes offset zero and the input endpoint.
    // Scope never discounts the source-content reservation.
    let bitmap = try add(input, 8) / 8
    let blobs = try add(query, template)
    var active: UInt64 = 65_536
    active = try add(active, multiply(input, by: 6))
    active = try add(active, multiply(output, by: 6))
    active = try add(active, multiply(matches, by: 32))
    active = try add(active, bitmap)
    active = try add(active, multiply(blobs, by: 3))

    // Publication keeps the declared ceilings, including empty-result metadata.
    var retained: UInt64 = 4_096
    retained = try add(retained, multiply(input, by: 3))
    retained = try add(retained, multiply(output, by: 3))
    retained = try add(retained, multiply(matches, by: 16))
    return SearchAdmissionCharge(active: active, retained: retained)
  }

  private func dimension(_ value: Int, maximum: Int) throws -> UInt64 {
    guard value >= 0, value <= maximum, let converted = UInt64(exactly: value) else {
      throw SearchAdmissionFailure.invalidDescriptor
    }
    return converted
  }

  private func blobUnits(_ text: String) throws -> UInt64 {
    let count = text.utf16.prefix(4_097).count
    return try dimension(count, maximum: searchWireMaximumRequestBlobUTF16)
  }

  private func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw SearchAdmissionFailure.resultBudget }
    return result.partialValue
  }

  private func multiply(_ value: UInt64, by factor: UInt64) throws -> UInt64 {
    let result = value.multipliedReportingOverflow(by: factor)
    guard !result.overflow else { throw SearchAdmissionFailure.resultBudget }
    return result.partialValue
  }
}
