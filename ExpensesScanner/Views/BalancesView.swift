import SwiftData
import SwiftUI

/// Who is up, who is down, and the fewest payments that make everyone even.
struct BalancesView: View {
    let trip: TripSnapshot
    let ledger: Ledger
    let onSettle: (Transfer) -> Void

    var body: some View {
        List {
            if !ledger.pendingRate.isEmpty || !ledger.missingPayer.isEmpty || ledger.unassigned != 0 {
                Section {
                    if !ledger.pendingRate.isEmpty {
                        Label(L10n.pendingRateNotice(ledger.pendingRate.count), systemImage: "exclamationmark.triangle")
                    }
                    if !ledger.missingPayer.isEmpty {
                        Label(L10n.missingPayerNotice(ledger.missingPayer.count), systemImage: "exclamationmark.triangle")
                    }
                    if ledger.unassigned != 0 {
                        Label(L10n.unassignedNotice(Money.format(ledger.unassigned, trip.homeCurrency)), systemImage: "questionmark.circle")
                    }
                }
                .foregroundStyle(.orange)
            }

            Section {
                if ledger.balances.isEmpty {
                    Text(L10n.noPeopleSubtitle)
                        .foregroundStyle(.secondary)
                }
                ForEach(ledger.balances) { balance in
                    BalanceRow(balance: balance, trip: trip)
                }
            } header: {
                Text(L10n.balancesIn(trip.homeCurrency))
            } footer: {
                Text(L10n.spentTotal(Money.format(ledger.spent, trip.homeCurrency)))
            }

            Section(L10n.settleUp) {
                if ledger.transfers.isEmpty {
                    Label(L10n.everyoneEven, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(ledger.transfers, id: \.self) { transfer in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.transferLine(trip.personName(transfer.from), trip.personName(transfer.to)))
                            Text(Money.format(transfer.amount, trip.homeCurrency))
                                .font(.headline.monospacedDigit())
                        }
                        Spacer(minLength: 8)
                        Button(L10n.markPaid) { onSettle(transfer) }
                            .buttonStyle(.bordered)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct BalanceRow: View {
    let balance: Balance
    let trip: TripSnapshot

    var body: some View {
        let person = trip.participant(balance.participant)
        HStack(spacing: 12) {
            ParticipantBadge(name: person?.name ?? "?", colorIndex: person?.colorIndex ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(person?.name ?? "?")
                Text(L10n.paidAndShare(Money.format(balance.paid, trip.homeCurrency), Money.format(balance.owed, trip.homeCurrency)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Money.formatSigned(balance.net, trip.homeCurrency))
                .font(.headline.monospacedDigit())
                .foregroundStyle(balance.net > 0 ? Color.green : balance.net < 0 ? Color.red : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The people on a trip: add, rename, remove.
struct ParticipantsSheet: View {
    let trip: Trip

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var prompt: TextPrompt?
    @State private var confirmation: Confirmation?
    @State private var blockedMessage: String?
    @FocusState private var adding: Bool

    private var store: TripStore { TripStore(context: context) }

    var body: some View {
        NavigationStack {
            List {
                if !trip.orderedParticipants.isEmpty {
                    Section {
                        ForEach(trip.orderedParticipants) { participant in
                            HStack(spacing: 12) {
                                ParticipantBadge(name: participant.name, colorIndex: participant.colorIndex)
                                Text(participant.name)
                            }
                            .swipeActions(edge: .trailing) {
                                Button { remove(participant) } label: {
                                    Label(L10n.delete, systemImage: "trash")
                                }
                                .tint(.red)
                                Button { rename(participant) } label: {
                                    Label(L10n.rename, systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button { rename(participant) } label: { Label(L10n.rename, systemImage: "pencil") }
                                Button(role: .destructive) { remove(participant) } label: {
                                    Label(L10n.delete, systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        TextField(L10n.addPerson, text: $newName)
                            .focused($adding)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button(L10n.add, action: add)
                            .disabled(newName.trimmed.isEmpty)
                    }
                } footer: {
                    Text(L10n.peopleFooter)
                }
            }
            .navigationTitle(L10n.people)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
            .onAppear {
                if trip.orderedParticipants.isEmpty { adding = true }
            }
            .textPrompt($prompt)
            .confirmation($confirmation)
            .alert(L10n.cannotRemoveTitle, isPresented: $blockedMessage.isPresent(), presenting: blockedMessage) { _ in
                Button(L10n.ok, role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func add() {
        let name = newName.trimmed
        guard !name.isEmpty else { return }
        store.addParticipant(to: trip, name: name)
        newName = ""
        adding = true
    }

    private func rename(_ participant: Participant) {
        prompt = TextPrompt(title: L10n.renamePerson, placeholder: L10n.personName, initialText: participant.name) { name in
            store.renameParticipant(participant, to: name)
        }
    }

    private func remove(_ participant: Participant) {
        guard store.canDelete(participant) else {
            blockedMessage = L10n.cannotRemoveMessage(participant.name)
            return
        }
        confirmation = Confirmation(
            title: L10n.removePerson,
            message: L10n.removePersonMessage(participant.name),
            confirmTitle: L10n.delete,
            destructive: true
        ) {
            store.deleteParticipant(participant)
        }
    }
}

/// Trip name and home currency.
struct TripSettingsSheet: View {
    let originalCurrency: CurrencyCode
    let hasExpenses: Bool
    let onSave: (_ name: String, _ homeCurrency: CurrencyCode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var currency: CurrencyCode

    init(name: String, homeCurrency: CurrencyCode, hasExpenses: Bool, onSave: @escaping (_ name: String, _ homeCurrency: CurrencyCode) -> Void) {
        originalCurrency = homeCurrency
        self.hasExpenses = hasExpenses
        self.onSave = onSave
        _name = State(initialValue: name)
        _currency = State(initialValue: homeCurrency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.tripName, text: $name)
                } header: {
                    Text(L10n.tripName)
                }
                Section {
                    NavigationLink {
                        CurrencyPicker(selection: $currency)
                    } label: {
                        LabeledContent(L10n.homeCurrency, value: Money.label(currency))
                    }
                } footer: {
                    if currency != originalCurrency && hasExpenses {
                        Text(L10n.homeCurrencyChangeWarning)
                            .foregroundStyle(.orange)
                    } else {
                        Text(L10n.homeCurrencyFooter)
                    }
                }
            }
            .navigationTitle(L10n.tripSettings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        onSave(name.trimmed, currency)
                        dismiss()
                    }
                    .disabled(name.trimmed.isEmpty)
                }
            }
        }
    }
}
