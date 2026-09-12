import SwiftUI

/// Asked once, the first time a version that has a window runs.
///
/// The app was a menu bar app for its whole life, so the window is a change
/// people did not ask for individually and cannot discover from an icon that
/// looks the same as yesterday. One question at launch, two answers, and it
/// never comes back.
struct PresentationChoiceView: View {
    /// `true` when the person wants the window and no menu bar icon.
    let choose: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "internaldrive")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 14)
            Text(L("Where should it live?"))
                .font(.title3.weight(.semibold))
            Text(L("The same panel either way: the menu bar keeps the size in sight, the window opens from Applications like any other app."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 8)
            HStack(spacing: 10) {
                Button(L("Use a window instead")) { choose(true) }
                Button(L("Keep the menu bar icon")) { choose(false) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 22)
            Text(L("You can change this any time in Settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .frame(width: 440)
    }
}
