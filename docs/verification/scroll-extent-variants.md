# Auxiliary text-view scroll extent variant investigation

Status: two visible native probes executed; five scrolling controls and printing passed. A separate Help window sizing defect was confirmed and narrowly fixed; retained regression checks were added.

The original editor bug violated this invariant: selecting and scrolling to an existing glyph must bring that glyph into the viewport. Its frame-initialized NSTextView retained a small maximum size despite a large text-container extent. Text and selection were intact, but middle/end content remained unreachable. Explicit zero minimum and unbounded maximum view dimensions fixed the retained editor regression.

The installed variant-analysis workflow was applied to related AppKit text controls. The exact editor initialization pattern was inspected in the captured spike; expanding to `NSTextView(` and then `isVerticallyResizable` across production sources identified HelpController, MarkdownPreviewController, ExternalCommandController (arguments and output), TextUtilitiesController, LargeFileWindowController, and DocumentPrinting. EditorWindowController and ComparisonController already explicitly set maximum dimensions. A repository-wide Swift search outside the production native source directory found no additional production NSTextView initializations. Missing `maxSize` alone is not a valid finding: zero-frame initializers may receive different defaults, and DocumentPrinting explicitly sets its view frame to the full laid-out text height.

The ignored `.local/spikes/scroll-variants/Probe.swift` compiles the six current production controllers with the isolated established PadCore library. It uses real Help content, synthetic 400-row Markdown, actual Base64 utility output, manually supplied external arguments and an explicitly invoked local printf command, a synthetic file through the byte-window reader, and the independent print-view builder. Each scrolling case lays out text, selects its final glyph, invokes `scrollRangeToVisible`, then compares that glyph's actual bounds to `visibleRect`; it records view maximum and frame dimensions. The printing case checks full used-height containment separately. The probe does not alter production controllers or fetch external resources.

Planned regression guard: retain runtime visibility assertions for each confirmed failure after a minimal fix. A source rule rejecting every NSTextView without explicit maxSize would also flag safe manual-frame printing and possibly zero-frame controls; it should not be introduced as an unconditional CI failure without this triage.

## First executed probe

The isolated process exited 0 in under one second. At the final synthetic glyph, Markdown (7,605 UTF-16 units), Utilities Base64 output (10,140), External arguments (7,604), External output from explicit printf (7,639), and the LargeFile byte page (7,604) all intersected the actual visible rectangle. Their native maximum heights were 10,000,000 points, unlike the original explicit-layout-manager editor's small maximum. These are informational negative findings for the tested data; absence of an explicit maxSize setter does not reproduce the original bug here.

The print view frame was 6,023 points high, containing its 6,015-point used text height. This rules out the suspected frame-extent failure in this fixture; it is not a physical printer or full pagination test.

Help's current built-in content with no supplied shortcuts produced a one-point-wide view and empty visibleRect immediately after showWindow. No scroll-limit diagnosis is assigned from this unsettled/empty viewport observation. A follow-up allowing the native run loop to settle is prepared; it must distinguish initial sizing from a persistent defect.

## Confirmed Help sizing defect and fix

P2, high confidence: current HelpController's initial window had a 1×32-point outer frame, a 1×0 content viewport, and a 1×550 text frame. The final glyph remained invisible after a 100 ms native run-loop settle. This is a window-fitting/sizing defect, not the original editor maximum-height defect: Help's maximum text height was already 10,000,000 points.

The retained `Tests/NativeIntegration/HelpHarness.swift` first failed against unchanged production code with “Help must provide a usable visible text viewport” (child exit -5). Moving the scroll view into the existing content view alone did not fix it. The final change preserves the existing content-view arrangement, sets a 400×320 minimum window size, and reapplies the intended 700×600 content size after installing the scroll view, before centering. No text or command behavior changes.

The regression checks the initial viewport before any manual resize, then start/end glyph visibility and exact text preservation at 700×600 and 440×360. The first green run used the built-in Help text with no shortcut descriptors. The retained fixture uses the application's actual command registry to exercise the complete shortcut list. The native integration script includes a focused Help compile/run entry. Physical VoiceOver and keyboard interaction remain outside this bounded structural test.

Final actual-registry Help regression exited 0 and passed all initial/start/end/resize assertions. The settled six-controller probe also repeated all five negative scroll findings and print-height coverage successfully.
