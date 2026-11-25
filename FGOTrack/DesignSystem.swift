import SwiftUI

// MARK: - Colors

/// Deep green used for the hero card background.
let ink = Color(red: 0.05, green: 0.20, blue: 0.16)
/// Filled primary actions. Stays dark so white labels remain readable in both appearances.
let accent = Color(red: 0.05, green: 0.40, blue: 0.30)
/// Tint for plain/bordered controls and icons; brighter in dark mode. Also the app-wide
/// AccentColor asset, so system sheets, alerts and pickers match.
let controlAccent = Color("AccentColor")
let canvas = Color(uiColor: .systemGroupedBackground)
let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

// MARK: - App information

enum AppInfo {
    static let supportEmail = "business@knoworganization.com"
    static let supportURL = URL(string: "mailto:\(supportEmail)")!
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

// MARK: - Components

struct BrandMark: View {
    var size: CGFloat = 76
    var body: some View {
        Image("BrandLogo").resizable().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A full-width filled action, e.g. "Scan receipt" or "Create account".
struct PrimaryButton<Label: View>: View {
    var loading = false
    let action: () -> Void
    @ViewBuilder let label: Label
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { if loading { ProgressView().tint(.white) }; label }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 30)
        }.buttonStyle(.borderedProminent).controlSize(.large).tint(accent)
    }
}

/// Rupee amount field with a fixed ₹ prefix and the decimal keypad.
struct AmountField<Focus: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .largeTitle
    var focus: FocusState<Focus?>.Binding
    var field: Focus
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("₹").font(font).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $text).keyboardType(.decimalPad).font(font).focused(focus, equals: field)
                .accessibilityLabel(placeholder)
        }
    }
}

extension View {
    /// Rounded grouped card used for summaries and category budgets.
    func card(padding: CGFloat = 18) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    /// Standalone text field outside a Form.
    func inputField() -> some View {
        self.padding(16).background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    /// Presents a single-button alert while `message` is non-nil, then clears it.
    func messageAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: { Text(message.wrappedValue ?? "") }
    }
}

extension Binding where Value == Bool {
    /// True while the optional has a value; setting false clears it. For item-driven dialogs.
    init<T>(present item: Binding<T?>) {
        self.init(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Opens the iOS Settings page for this app (camera permission recovery).
@MainActor func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}
