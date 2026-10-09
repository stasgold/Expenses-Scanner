import PhotosUI
import SwiftData
import SwiftUI
import UIKit

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
    @State private var receipt: ReceiptSession?
    @State private var showScanner = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var reading = false
    @State private var readFailed = false

    /// A receipt open for review: just scanned (`expenseID` nil) or saved earlier.
    private struct ReceiptSession: Identifiable {
        let id = UUID()
        var draft: ReceiptExpenseDraft
        var expenseID: UUID?
    }

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
                Menu {
                    addMenu(trip)
                } label: {
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
                targetLanguage: trip.targetLanguage,
                hasExpenses: !snapshot.expenses.isEmpty
            ) { name, currency, language in
                store.updateTrip(trip, name: name, homeCurrency: currency)
                store.setTargetLanguage(trip, language)
            }
        }
        .sheet(item: $receipt) { session in
            ReceiptEditorView(
                isNew: session.expenseID == nil,
                participants: trip.snapshot.participants,
                homeCurrency: trip.homeCurrency,
                draft: session.draft,
                targetLanguage: trip.targetLanguage,
                onTargetLanguage: { store.setTargetLanguage(trip, $0) }
            ) { draft in
                if let id = session.expenseID, let expense = trip.orderedExpenses.first(where: { $0.uuid == id }) {
                    store.updateReceipt(expense, draft)
                } else {
                    _ = store.addReceipt(to: trip, draft)
                }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(
                onScan: { pages in
                    showScanner = false
                    read(pages, for: trip)
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            loadPhoto(item, for: trip)
        }
        .overlay {
            if reading {
                ProgressView(L10n.readingReceipt)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(L10n.readFailedTitle, isPresented: $readFailed) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(L10n.readFailedMessage)
        }
        .confirmation($confirmation)
        // Expenses in other currencies get their rate as soon as one can be fetched.
        .task(id: RateUpdater.pendingKey(trip)) {
            await RateUpdater.fill(trip, store: store)
        }
    }

    /// Scan, pick a photo, or type it in.
    @ViewBuilder
    private func addMenu(_ trip: Trip) -> some View {
        if DocumentScanner.isAvailable {
            Button { startScan(trip) } label: {
                Label(L10n.scanReceipt, systemImage: "doc.viewfinder")
            }
        }
        Button { choosePhoto(trip) } label: {
            Label(L10n.choosePhoto, systemImage: "photo")
        }
        Button { addExpense(to: trip) } label: {
            Label(L10n.enterManually, systemImage: "square.and.pencil")
        }
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
                if snapshot.participants.isEmpty {
                    Button(L10n.addPeople) { showParticipants = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        if DocumentScanner.isAvailable { startScan(trip) } else { choosePhoto(trip) }
                    } label: {
                        Label(DocumentScanner.isAvailable ? L10n.scanReceipt : L10n.choosePhoto, systemImage: "doc.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L10n.enterManually) { addExpense(to: trip) }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(snapshot.expenses) { expense in
                    Button {
                        open(expense, in: trip)
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
                            Button { open(expense, in: trip) } label: { Label(L10n.edit, systemImage: "pencil") }
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

    /// Receipts open in the receipt editor, typed-in expenses in theirs; transfers aren't edited.
    private func open(_ expense: ExpenseSnapshot, in trip: Trip) {
        switch expense.kind {
        case .manual:
            editor = .edit(expense.id)
        case .receipt:
            if let model = trip.orderedExpenses.first(where: { $0.uuid == expense.id }) {
                receipt = ReceiptSession(draft: store.receiptDraft(for: model), expenseID: model.uuid)
            }
        case .transfer:
            break
        }
    }

    private func startScan(_ trip: Trip) {
        if trip.orderedParticipants.isEmpty {
            showParticipants = true
        } else {
            showScanner = true
        }
    }

    private func choosePhoto(_ trip: Trip) {
        if trip.orderedParticipants.isEmpty {
            showParticipants = true
        } else {
            showPhotoPicker = true
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem, for trip: Trip) {
        reading = true
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                read([image], for: trip)
            } else {
                reading = false
                readFailed = true
            }
        }
    }

    /// Reads the receipt on the device, then opens it for review.
    private func read(_ pages: [UIImage], for trip: Trip) {
        guard !pages.isEmpty else { return }
        reading = true
        let currency = lastCurrency(in: trip)
        let people = trip.snapshot.participants.map(\.id)
        Task {
            defer { reading = false }
            do {
                let scanned = try await ReceiptScanner.scan(pages)
                let rows = LineGrouper.rows(scanned.fragments)
                let parsed = ReceiptParser.parse(rows, currency: currency)
                let draft = ReceiptExpenseDraft(
                    parsed: parsed, rows: rows, currency: currency, date: Date(),
                    payer: people.first, participants: people, photo: scanned.photo
                )
                receipt = ReceiptSession(draft: draft, expenseID: nil)
            } catch {
                readFailed = true
            }
        }
    }

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
        let amount = "≈ " + Money.format(home, trip.homeCurrency)
        return expense.rateIsApproximate ? amount + " · " + L10n.offlineRate : amount
    }
}
