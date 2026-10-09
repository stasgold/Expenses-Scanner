import SwiftUI
import Translation

/// Pick the language receipts are translated into: the phone's, or any language the iPhone can
/// translate into.
struct LanguagePicker: View {
    /// BCP 47 identifier; nil follows the phone.
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var languages: [Locale.Language] = []
    @State private var query = ""

    private var filtered: [Locale.Language] {
        let needle = query.trimmed
        guard !needle.isEmpty else { return languages }
        return languages.filter { Languages.name($0).localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List {
            if query.trimmed.isEmpty {
                Section {
                    row(L10n.phoneLanguage(Languages.name(Languages.phone)), selected: selection == nil) {
                        selection = nil
                    }
                }
            }
            Section {
                ForEach(filtered, id: \.minimalIdentifier) { language in
                    row(Languages.name(language), selected: selection == language.minimalIdentifier) {
                        selection = language.minimalIdentifier
                    }
                }
            }
        }
        .overlay {
            if languages.isEmpty { ProgressView() }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(L10n.translateTo)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let supported = await LanguageAvailability().supportedLanguages
            var seen = Set<String>()
            languages = supported
                .filter { seen.insert($0.minimalIdentifier).inserted }
                .sorted { Languages.name($0).localizedCompare(Languages.name($1)) == .orderedAscending }
        }
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The whole receipt, line by line in the reader's language, with the amounts exactly as printed.
struct TranslatedReceiptView: View {
    let rows: [ReceiptRow]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    let words = ReceiptParser.cleanName(row.text)
                    let amount = Self.amount(in: row)
                    if !words.isEmpty || amount != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.translation ?? words)
                                if row.translation != nil, row.translation != words {
                                    Text(words)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if let amount {
                                Text(amount)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.translatedReceipt)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
        }
    }

    /// The right-most amount on the line, as printed ("¥8,360").
    static func amount(in row: ReceiptRow) -> String? {
        row.text.split(whereSeparator: \.isWhitespace).last { ReceiptParser.moneyToken(String($0)) != nil }.map(String.init)
    }
}
