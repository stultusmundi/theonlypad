# Document statistics

Scope: requirement B-08 (see matrix for canonical ID/text). Provide accurate, explicitly labeled document and selection counts without blocking editing for large buffers.

Planned contract: a pure service measures grapheme characters, UTF16 units, UTF8 bytes without BOM, LF/CRLF/CR endings and logical lines, and selection characters/units. Byte count is explicitly separate from original saved-file bytes and save encoding. Validate ranges including surrogate boundaries; support cooperative cancellation. Native command captures an immutable snapshot and analyzes off-main.

Implemented: DocumentStatistics and tool.statistics. Starting another analysis or closing the editor cancels pending work; generation checks prevent old results replacing a newer request. Native alert labels the invocation snapshot and its byte units. No file is written.

Tested: red missing-type tests followed by two green DocumentStatisticsTests covering emoji, combining marks, mixed endings, trailing empty lines and invalid selections. Integrated native alert-content check added; latest result must be recorded after execution. More complete Unicode separator/gutter consistency, large-buffer responsiveness and physical desktop accessibility remain outstanding.

Commands: `scripts/swift.sh test --filter DocumentStatisticsTests`; `scripts/test-native-integration.sh`.
