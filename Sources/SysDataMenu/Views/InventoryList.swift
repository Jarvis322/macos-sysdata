import SwiftUI

/// Keep inventory rows out of NSTableView's self-sizing layout cycle. On
/// macOS 26, scrolling the table-backed List can repeatedly invalidate its
/// hosting views' constraints until AppKit raises NSGenericException.
/// Selection is managed by the row checkboxes, not by List selection.
struct InventoryList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
