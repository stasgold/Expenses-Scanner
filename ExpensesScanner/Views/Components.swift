import SwiftUI

/// A person's initials in their colour.
struct ParticipantBadge: View {
    let name: String
    let colorIndex: Int
    var size: CGFloat = 32

    var body: some View {
        let accent = ParticipantPalette.accent(for: colorIndex)
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(accent.onContainer)
            .frame(width: size, height: size)
            .background(accent.container, in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Searchable list of currencies; picking one sets `selection` and goes back.
struct CurrencyPicker: View {
    @Binding var selection: CurrencyCode
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var currencies: [CurrencyCode] {
        let all = Money.allCurrencies
        let needle = query.trimmed
        guard !needle.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(needle) || Money.name($0).localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List(currencies, id: \.self) { code in
            Button {
                selection = code
                dismiss()
            } label: {
                HStack {
                    Text(code)
                        .font(.body.monospaced())
                        .frame(width: 52, alignment: .leading)
                    Text(Money.name(code))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if code == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityAddTraits(code == selection ? .isSelected : [])
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(L10n.currency)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Money {
    /// "EUR · Euro"
    static func label(_ currency: CurrencyCode) -> String {
        "\(currency) · \(name(currency))"
    }
}
