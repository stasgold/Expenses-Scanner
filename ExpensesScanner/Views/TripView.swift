import SwiftData
import SwiftUI

/// One trip: its expenses, or who owes whom.
struct TripView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [Trip]

    @State private var tab = Tab.expenses
    @State private var editor: EditorRoute?
    @State private var showParticipants = false
    @State private var showSettings = false
    @State private var confirmation: Confirmation?

    private enum Tab: Hashable {
        case expenses, balances
    }

    private enum EditorRoute: Identifiable {
        case new
        case edit(UUID)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let id): return id.uuidString
            }
        }
    }

    init(tripID: UUID) {
        _matches = Query(filter: #Predicate<Trip> { $0.uuid == tripID })
    }

    private var store: TripStore { TripStore(context: context) }
    private var trip: Trip? { matches.first.flatMap { $0.isDeleted ? nil : $0 } }

    var body: some View {
        Group {
            if let trip {
                content(trip)
            } else {
                Color.clear
            }
        }
        // The trip was deleted underneath us (another window, a stale route): leave.
        .onChange(of: trip == nil, initial: true) { _, missing in
            if missing { dismiss() }
        }
    }

    @ViewBuilder
    private func content(_ trip: Trip) -> some View {
        let snapshot = trip.snapshot
        let ledger = Ledger(snapshot)

        VStack(spacing: 0) {
            Picker(L10n.view, selection: $tab) {
                Text(L10n.expenses).tag(Tab.expenses)
                Text(L10n.balances).tag(Tab.balances)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .expenses:
                expenses(of: trip, snapshot: snapshot)
            case .balances:
                BalancesView(trip: snapshot, ledger: ledger) { transfer in
                    confirmSettle(transfer, in: trip, snapshot: snapshot)
                }
            }
        }
        .navigationTitle(trip.name.isEmpty ? L10n.untitledTrip : trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addExpense(to: trip) } label: {
                    Label(L10n.addExpense, systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showParticipants = true } label: {
                        Label(L10n.people, systemImage: "person.2")
                    }
                    Button { showSettings = true } label: {
                        Label(L10n.tripSettings, systemImage: "gearshape")
                    }
                    ShareLink(item: TripShareFormatter.text(snapshot), subject: Text(snapshot.name)) {
                        Label(L10n.share, systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label(L10n.more, systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editor) { route in
            editorSheet(route, trip: trip)
        }
        .sheet(isPresented: $showParticipants) {
            ParticipantsSheet(trip: trip)
        }
        .sheet(isPresented: $showSettings) {
            TripSettingsSheet(
                name: trip.name,
                homeCurrency: trip.homeCurrency,
                hasExpenses: !snapshot.expenses.isEmpty
            ) { name, currency in
                store.updateTrip(trip, name: name, homeCurrency: currency)
            }
        }
        .confirmation($confirmation)
    }

    // MARK: Expenses tab

    @ViewBuilder
    private func expenses(of trip: Trip, snapshot: TripSnapshot) -> some View {
        if snapshot.expenses.isEmpty {
            ContentUnavailableView {
                Label(L10n.noExpensesTitle, systemImage: "receipt")
            } description: {
                Text(snapshot.participants.isEmpty ? L10n.noPeopleSubtitle : L10n.noExpensesSubtitle)
            } actions: {
                Button(snapshot.participants.isEmpty ? L10n.addPeople : L10n.addExpense) { addExpense(to: trip) }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(snapshot.expenses) { expense in
                    Button {
                        if expense.kind != .transfer { editor = .edit(expense.id) }
                    } label: {
                        ExpenseRow(expense: expense, trip: snapshot)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button { confirmDelete(expense, in: trip, snapshot: snapshot) } label: {
                            Label(L10n.delete, systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        if expense.kind != .transfer {
                            Button { editor = .edit(expense.id) } label: { Label(L10n.edit, systemImage: "pencil") }
                        }
                        Button(role: .destructive) { confirmDelete(expense, in: trip, snapshot: snapshot) } label: {
                            Label(L10n.delete, systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func editorSheet(_ route: EditorRoute, trip: Trip) -> some View {
        let participants = trip.snapshot.participants
        switch route {
        case .new:
            ExpenseEditorSheet(
                isNew: true,
                participants: participants,
                homeCurrency: trip.homeCurrency,
                draft: ManualExpenseDraft(
                    currency: lastCurrency(in: trip),
                    payerID: participants.first?.id,
                    weights: Dictionary(uniqueKeysWithValues: participants.map { ($0.id, 1) })
                )
            ) { draft in
                _ = store.addExpense(to: trip, draft)
            }
        case .edit(let id):
            if let expense = trip.orderedExpenses.first(where: { $0.uuid == id }) {
                ExpenseEditorSheet(
                    isNew: false,
                    participants: participants,
                    homeCurrency: trip.homeCurrency,
                    draft: store.draft(for: expense)
                ) { draft in
                    store.updateExpense(expense, draft)
                }
            }
        }
    }

    // MARK: Actions

    private func addExpense(to trip: Trip) {
        if trip.orderedParticipants.isEmpty {
            showParticipants = true
        } else {
            editor = .new
        }
    }

    /// New expenses start in the currency of the latest one: abroad, that's usually the local money.
    private func lastCurrency(in trip: Trip) -> CurrencyCode {
        trip.orderedExpenses.first { $0.kind != .transfer }?.currency ?? trip.homeCurrency
    }

    private func confirmDelete(_ expense: ExpenseSnapshot, in trip: Trip, snapshot: TripSnapshot) {
        confirmation = Confirmation(
            title: L10n.deleteExpense,
            message: L10n.deleteExpenseMessage(snapshot.title(of: expense)),
            confirmTitle: L10n.delete,
            destructive: true
        ) {
            if let model = trip.orderedExpenses.first(where: { $0.uuid == expense.id }) {
                store.deleteExpense(model)
            }
        }
    }

    private func confirmSettle(_ transfer: Transfer, in trip: Trip, snapshot: TripSnapshot) {
        let amount = Money.format(transfer.amount, snapshot.homeCurrency)
        confirmation = Confirmation(
            title: L10n.markPaid,
            message: L10n.markPaidMessage(snapshot.personName(transfer.from), snapshot.personName(transfer.to), amount),
            confirmTitle: L10n.markPaid
        ) {
            _ = store.recordTransfer(in: trip, transfer)
        }
    }
}

/// One expense in the list: what, who paid, how much (and how much at home).
struct ExpenseRow: View {
    let expense: ExpenseSnapshot
    let trip: TripSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title(of: expense))
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(expense.input.total, expense.currency))
                    .font(.body.monospacedDigit())
                if let home = homeAmount {
                    Text(home)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch expense.kind {
        case .transfer: return "arrow.left.arrow.right"
        case .receipt: return "receipt"
        case .manual: return "creditcard"
        }
    }

    private var subtitle: String {
        let date = expense.date.formatted(date: .abbreviated, time: .omitted)
        guard expense.kind != .transfer else { return date }
        return "\(L10n.paidBy(trip.personName(expense.payer))) · \(date)"
    }

    /// "≈ €9.10" for a foreign expense, or a reminder that it has no rate yet.
    private var homeAmount: String? {
        guard expense.currency.uppercased() != trip.homeCurrency.uppercased() else { return nil }
        guard let home = trip.homeTotal(of: expense) else { return L10n.noRateYet }
        return "≈ " + Money.format(home, trip.homeCurrency)
    }
}
