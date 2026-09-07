# Scrolling during a scan: diagnostic evidence

This is an unresolved crash investigation, not a verified fix. The proposed eager
VStack replacement has been withdrawn: the original synthetic test also passes
against List, and eagerly building every row regresses virtualization and appearance.
The production List, inset styling, and separators are preserved.

## Reported conditions

- SysDataMenu v0.4.7, macOS 26.5.2 (25F84), Apple Silicon.
- The user reports crashes when scrolling before scanning completes, but not when
  waiting for the scan to finish before scrolling.
- The maintainer reports no reproduction on macOS 26.6.2 (25G83).
- Row count and display/accessibility configuration at the exact crash time were
  not captured. Current display configuration must not be assumed to be historical.

## Saved system log

The original .ips files are no longer present in the diagnostic directory. These
excerpts are from the unified-log export saved during the original investigation;
they are not a reconstructed .ips. The exception reason is redacted by macOS as
`<private>`, so it is unavailable in this export.

Three separate SysDataMenu processes logged `NSGenericException` on September 7,
2026, at 22:31:51.847, 22:32:02.185, and 22:32:20.874 (local time, UTC+8).
Immediately before the first exception, AppKit repeatedly logged window layout
invalidation, including `limit: 174, count: 87 w/identifier 2048` and later counts.

First exception (memory addresses and process identifiers omitted):

```text
FAULT: NSGenericException: <private>; (user info absent)
0   CoreFoundation                      __exceptionPreprocess + 176
1   libobjc.A.dylib                     objc_exception_throw + 88
2   CoreFoundation                      +[NSException exceptionWithName:reason:userInfo:] + 0
3   AppKit                              -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints] + 1716
4   AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
5   AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
6   AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
7   AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
8   AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
9   AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
10  AppKit                              -[_NSConstraintBasedLayoutHostingView _informContainerThatSubviewsNeedUpdateConstraints] + 52
11  AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
12  AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
13  AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
14  AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
15  AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
16  AppKit                              -[NSView _informContainerThatSubviewsNeedUpdateConstraints] + 64
17  AppKit                              -[NSView setNeedsUpdateConstraints:] + 468
18  SwiftUI                             $s7SwiftUI13NSHostingViewC14setNeedsUpdateyyF + 176
19  SwiftUI                             $s7SwiftUI13NSHostingViewC13requestUpdate5afterySd_tF + 676
20  SwiftUICore                         $s7SwiftUI25ViewGraphRootValueUpdaterPAAE20invalidateProperties_14mayDeferUpdateyAA0cdE6ValuesV_SbtFyyXEfU_ + 228
21  SwiftUICore                         $s7SwiftUI25ViewGraphRootValueUpdaterPAAE20invalidateProperties_14mayDeferUpdateyAA0cdE6ValuesV_SbtF + 192
22  SwiftUI                             $s7SwiftUI13NSHostingViewC13rootTransformAA0dF0VyFySo6NSViewCcfU_TA + 44
23  SwiftUI                             $sSo6NSViewCIegg_ABIeyBy_TR + 56
24  AppKit                              -[_NSViewGeometryInWindowConcreteObservation _geometryInWindowDidChange:] + 204
25  CoreFoundation                      __CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__ + 148
26  CoreFoundation                      ___CFXRegistrationPost_block_invoke + 92
27  CoreFoundation                      _CFXRegistrationPost + 440
28  CoreFoundation                      _CFXNotificationPost + 740
29  Foundation                          -[NSNotificationCenter postNotificationName:object:userInfo:] + 88
30  AppKit                              NSViewHierarchyNoteGeometryInWindowDidChange + 156
31  AppKit                              NSViewHierarchyNoteGeometryInWindowDidChange + 316
32  AppKit                              -[NSView _invalidateFocus] + 68
33  AppKit                              -[NSView setFrameSize:] + 1380
34  AppKit                              -[NSTableCellView setFrameSize:] + 104
35  AppKit                              -[NSView setFrame:] + 300
36  AppKit                              NSViewActuallyUpdateFrameFromLayoutEngine + 236
37  AppKit                              -[NSView layout] + 636
38  AppKit                              -[NSTableRowView layout] + 60
```

The raising frame is `NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints`.
The stack also contains `NSTableCellView setFrameSize:` and `NSTableRowView layout`.
This supports investigating constraint invalidation during table layout. It does
not establish which view or data update triggers it, or prove a SwiftUI List bug.

## Reproduction status

The original synthetic test passed against both List and the replacement. It has
been removed from this PR rather than described as a regression test.

An additional local diagnostic attempt mounted the actual MenuView and ScanModel,
allowed real probes to run, and sent pixel wheel events. It reached a native table
while `isScanning` was true, but the process exited without a test completion
record or the reported exception. That run is inconclusive, not a pass or a
reproduction, and the unfinished harness is not included as a test.

The actual MenuBarExtra panel, pointer hover, and exact inventory at failure still
need to be captured. A future fix should preserve List virtualization and appearance
and be checked against a failing scenario before being proposed as a resolution.
