import SwiftUI

/// Add or edit a typed-in expense: what, how much, in which currency, who paid, who shares it.
struct ExpenseEditorSheet: View {
    let isNew: Bool
    let participants: [ParticipantSnapshot]
    let homeCurrency: CurrencyCode
    /// Set when editing a saved expense: deletes it.
    let onDelete: (() -> Void)?
    let onSave: (ManualExpenseDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManualExpenseDraft
    @State private var amountText: String
    @State private var rateText: String
    @FocusState private var focus: Field?

    private enum Field {
        case title, amount
    }

    init(
        isNew: Bool,
        participants: [ParticipantSnapshot],
        homeCurrency: CurrencyCode,
        draft: ManualExpenseDraft,
        onDelete: (() -> Void)? = nil,
        onSave: @escaping (ManualExpenseDraft) -> Void
    ) {
        self.isNew = isNew
        self.participants = participants
        self.homeCurrency = homeCurrency
        self.onDelete = onDelete
        self.onSave = onSave
        _draft = State(initialValue: draft)
        _amountText = State(initialValue: draft.amount > 0 ? Money.editableText(draft.amount, draft.currency) : "")
        _rateText = State(initialValue: draft.rateToHome.map(Money.rateText) ?? "")
    }

    private var amount: Int64? { Money.parse(amountText, draft.currency) }
    private var isForeign: Bool { draft.currency.uppercased() != homeCurrency.uppercased() }

    /// The draft with the typed amount and rate filled in.
    private var result: ManualExpenseDraft {
        var result = draft
        result.title = draft.title.trimmed
        result.amount = amount ?? 0
        result.rateToHome = isForeign ? Money.parseRate(rateText) : nil
        // Shares for people no longer on the trip don't count.
        result.weights = draft.weights.filter { id, _ in participants.contains { $0.id == id } }
        return result
    }

    private var amountInvalid: Bool { !amountText.trimmed.isEmpty && amount == nil }
    private var rateInvalid: Bool { isForeign && !rateText.trimmed.isEmpty && Money.parseRate(rateText) == nil }
    private var canSave: Bool { result.isValid && !rateInvalid }

    var body: some View {
        NavigationStack {
            Form {
                whatSection
                if isForeign {
                    RateSection(currency: draft.currency, homeCurrency: homeCurrency, date: draft.date, amount: amount, rateText: $rateText)
                }
                Section {
                    Picker(L10n.paidByLabel, selection: $draft.payerID) {
                        ForEach(participants) { participant in
                            Text(participant.name).tag(Optional(participant.id))
                        }
                    }
                }
                splitSection
                if let onDelete {
                    DeleteSection(
                        title: L10n.deleteExpense,
                        message: L10n.deleteExpenseMessage(draft.title.trimmed.isEmpty ? L10n.untitledExpense : draft.title.trimmed)
                    ) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle(isNew ? L10n.newExpense : L10n.editExpense)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        guard canSave else { return }
                        onSave(result)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if isNew { focus = .title }
            }
        }
    }

    private var whatSection: some View {
        Section {
            TextField(L10n.expenseTitle, text: $draft.title, prompt: Text(L10n.expenseTitleHint))
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .onSubmit { focus = .amount }
            HStack {
                TextField(L10n.amount, text: $amountText, prompt: Text(Money.editableText(0, draft.currency)))
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .amount)
                    .font(.title2.monospacedDigit())
                Text(draft.currency)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                CurrencyPicker(selection: $draft.currency)
            } label: {
                LabeledContent(L10n.currency, value: Money.label(draft.currency))
            }
            DatePicker(L10n.date, selection: $draft.date, displayedComponents: .date)
        } footer: {
            if amountInvalid {
                Text(L10n.amountError).foregroundStyle(.red)
            }
        }
    }

    private var splitSection: some View {
        let parts = Split.allocate(amount ?? 0, weights: participants.map { Int64(max(draft.weights[$0.id] ?? 0, 0)) })
        let everyoneIn = participants.allSatisfy { (draft.weights[$0.id] ?? 0) > 0 }
        return Section {
            ForEach(participants.indices, id: \.self) { index in
                let participant = participants[index]
                let part = parts[index]
                Stepper(value: weight(of: participant.id), in: 0...20) {
                    HStack(spacing: 12) {
                        ParticipantBadge(name: participant.name, colorIndex: participant.colorIndex)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(participant.name)
                            Text(sharesLabel(draft.weights[participant.id] ?? 0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if part != 0 {
                            Text(Money.format(part, draft.currency))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityValue(sharesLabel(draft.weights[participant.id] ?? 0))
            }
        } header: {
            HStack {
                Text(L10n.splitBetween)
                Spacer()
                Button(everyoneIn ? L10n.nobody : L10n.everyone) {
                    let weight = everyoneIn ? 0 : 1
                    for participant in participants { draft.weights[participant.id] = weight }
                }
                .font(.caption)
            }
            .textCase(nil)
        } footer: {
            Text(L10n.sharesFooter)
        }
    }

    private func weight(of id: UUID) -> Binding<Int> {
        Binding(
            get: { draft.weights[id] ?? 0 },
            set: { draft.weights[id] = $0 }
        )
    }

    private func sharesLabel(_ weight: Int) -> String {
        switch weight {
        case ...0: return L10n.notIncluded
        case 1: return L10n.oneShare
        default: return L10n.sharesCount(weight)
        }
    }
}
