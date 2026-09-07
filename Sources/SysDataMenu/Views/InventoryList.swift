import SwiftUI

/// Keep inventory rows out of NSTableView's self-sizing layout cycle. On
/// macOS 26, scrolling the table-backed List can repeatedly invalidate its
/// hosting views' constraints until AppKit raises NSGenericException.
/// Scan batches can insert entire categories above the viewport. Use eager
/// layout for this bounded inventory (typically around 180 items), avoiding
/// lazy height estimation while rows are inserted during scrolling.
/// Selection is managed by the row checkboxes, not by List selection.
struct InventoryList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
