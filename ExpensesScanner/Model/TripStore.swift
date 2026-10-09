import Foundation
import SwiftData

/// A typed-in expense as the editor holds it: one amount shared by weight.
struct ManualExpenseDraft: Equatable {
    var title: String = ""
    var amount: Int64 = 0
    var currency: CurrencyCode
    var date: Date = Date()
    var payerID: UUID?
    /// Shares per person: 1 is a normal share, 2 counts double, 0 (or missing) means not in it.
    var weights: [UUID: Int] = [:]
    /// One unit of `currency` in the home currency, typed by the user. Ignored for the home currency.
    var rateToHome: Decimal?

    var isValid: Bool {
        amount > 0 && payerID != nil && weights.values.contains { $0 > 0 }
    }
}

/**
 * Every write the UI makes goes through here, so views never mutate models directly.
 * Each method saves immediately: an expense that was on screen must still be there after the app is
 * killed, and SwiftData's autosave alone runs too late to guarantee that.
 */
@MainActor
struct TripStore {
    let context: ModelContext

    // MARK: Trips

    /// Blank names are skipped; people keep the order given.
    @discardableResult
    func createTrip(name: String, homeCurrency: CurrencyCode, people: [String]) -> Trip {
        let trip = Trip(name: name.trimmed, homeCurrency: homeCurrency.uppercased())
        context.insert(trip)
        for person in people.map(\.trimmed) where !person.isEmpty {
            insertParticipant(into: trip, name: person)
        }
        save()
        return trip
    }

    /**
     * Changing the home currency drops every exchange rate: they were all into the old one. Expenses in
     * other currencies then wait for a new rate (and are left out of balances until they have one).
     */
    func updateTrip(_ trip: Trip, name: String, homeCurrency: CurrencyCode) {
        trip.name = name.trimmed
        let currency = homeCurrency.uppercased()
        if currency != trip.homeCurrency {
            trip.homeCurrency = currency
            for expense in trip.expenses where !expense.isDeleted {
                clearRate(of: expense)
            }
        }
        touch(trip)
        save()
    }

    func deleteTrip(_ trip: Trip) {
        context.delete(trip)
        save()
    }

    // MARK: People

    @discardableResult
    func addParticipant(to trip: Trip, name: String) -> Participant {
        let participant = insertParticipant(into: trip, name: name.trimmed)
        touch(trip)
        save()
        return participant
    }

    func renameParticipant(_ participant: Participant, to name: String) {
        participant.name = name.trimmed
        touch(participant.trip)
        save()
    }

    /// Someone who paid for something, or sent or received a payment, has to stay: removing them would
    /// rewrite what others owe.
    func canDelete(_ participant: Participant) -> Bool {
        guard let trip = participant.trip else { return true }
        return !trip.expenses.contains { expense in
            !expense.isDeleted && (
                expense.payerID == participant.uuid
                    || (expense.kind == .transfer && expense.items.contains { $0.shares.contains { $0.participantID == participant.uuid } })
            )
        }
    }

    /// Removes the person and their shares. Lines only they had become unassigned.
    func deleteParticipant(_ participant: Participant) {
        guard canDelete(participant) else { return }
        let trip = participant.trip
        for expense in trip?.expenses ?? [] {
            for item in expense.items {
                for share in item.shares where share.participantID == participant.uuid {
                    context.delete(share)
                }
            }
        }
        context.delete(participant)
        touch(trip)
        save()
    }

    // MARK: Expenses

    @discardableResult
    func addExpense(to trip: Trip, _ draft: ManualExpenseDraft) -> Expense {
        let expense = Expense(title: draft.title.trimmed, date: draft.date, currency: draft.currency.uppercased(), kindRaw: ExpenseKind.manual.rawValue)
        context.insert(expense)
        trip.expenses.append(expense)
        let item = ExpenseItem(name: expense.title, amount: 0, position: 0)
        context.insert(item)
        expense.items.append(item)
        apply(draft, to: expense, in: trip)
        touch(trip)
        save()
        return expense
    }

    func updateExpense(_ expense: Expense, _ draft: ManualExpenseDraft) {
        guard let trip = expense.trip else { return }
        expense.title = draft.title.trimmed
        expense.date = draft.date
        apply(draft, to: expense, in: trip)
        touch(trip)
        save()
    }

    func deleteExpense(_ expense: Expense) {
        let trip = expense.trip
        context.delete(expense)
        touch(trip)
        save()
    }

    /// Records a settle-up payment; balances move through the same maths as any expense.
    @discardableResult
    func recordTransfer(in trip: Trip, _ transfer: Transfer, date: Date = Date()) -> Expense {
        let expense = Expense(title: "", date: date, currency: trip.homeCurrency, kindRaw: ExpenseKind.transfer.rawValue)
        context.insert(expense)
        trip.expenses.append(expense)
        expense.payerID = transfer.from
        let item = ExpenseItem(name: "", amount: transfer.amount, position: 0)
        context.insert(item)
        expense.items.append(item)
        let share = ItemShare(participantID: transfer.to, weight: 1)
        context.insert(share)
        item.shares.append(share)
        touch(trip)
        save()
        return expense
    }

    /// The editor's starting point for an existing manual expense.
    func draft(for expense: Expense) -> ManualExpenseDraft {
        var weights: [UUID: Int] = [:]
        for share in expense.orderedItems.first?.shares ?? [] where !share.isDeleted {
            weights[share.participantID, default: 0] += share.weight
        }
        return ManualExpenseDraft(
            title: expense.title,
            amount: expense.orderedItems.reduce(0) { $0 + $1.amount },
            currency: expense.currency,
            date: expense.date,
            payerID: expense.payerID,
            weights: weights,
            rateToHome: expense.rateSource == .manual ? expense.rate : nil
        )
    }

    // MARK: Helpers

    func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("Saving expenses failed: \(error)")
        }
    }

    @discardableResult
    private func insertParticipant(into trip: Trip, name: String) -> Participant {
        let position = (trip.orderedParticipants.map(\.position).max() ?? -1) + 1
        let participant = Participant(name: name, position: position, colorIndex: position % ParticipantPalette.count)
        context.insert(participant)
        trip.participants.append(participant)
        return participant
    }

    /// Writes a manual draft into its expense: the single line, its shares, the payer and the rate.
    private func apply(_ draft: ManualExpenseDraft, to expense: Expense, in trip: Trip) {
        expense.payerID = draft.payerID
        let currency = draft.currency.uppercased()
        let currencyChanged = expense.currency != currency
        expense.currency = currency

        let item: ExpenseItem
        if let existing = expense.orderedItems.first {
            item = existing
        } else {
            item = ExpenseItem(name: "", amount: 0, position: 0)
            context.insert(item)
            expense.items.append(item)
        }
        item.name = expense.title
        item.amount = draft.amount
        for share in item.shares { context.delete(share) }
        item.shares = []
        for participant in trip.orderedParticipants {
            let weight = draft.weights[participant.uuid] ?? 0
            guard weight > 0 else { continue }
            let share = ItemShare(participantID: participant.uuid, weight: weight)
            context.insert(share)
            item.shares.append(share)
        }

        if currency == trip.homeCurrency {
            clearRate(of: expense)
        } else if let rate = draft.rateToHome {
            expense.rate = rate
            expense.rateSource = .manual
            expense.rateDate = draft.date
            expense.rateFetchedAt = nil
        } else if expense.rateSource == .manual || currencyChanged {
            // The user cleared their own rate, or the old rate was for another currency: wait for a new one.
            clearRate(of: expense)
        }
    }

    private func clearRate(of expense: Expense) {
        expense.rate = nil
        expense.rateDate = nil
        expense.rateSource = nil
        expense.rateFetchedAt = nil
    }

    /// Bumps `updatedAt` so the trips list shows the most recently used trip first.
    private func touch(_ trip: Trip?) {
        trip?.updatedAt = Date()
    }
}

extension Trip {
    var snapshot: TripSnapshot {
        TripSnapshot(
            name: name,
            homeCurrency: homeCurrency,
            participants: orderedParticipants.map { ParticipantSnapshot(id: $0.uuid, name: $0.name, colorIndex: $0.colorIndex) },
            expenses: orderedExpenses.map { expense in
                ExpenseSnapshot(
                    id: expense.uuid,
                    title: expense.title,
                    kind: expense.kind,
                    date: expense.date,
                    currency: expense.currency,
                    payer: expense.payerID,
                    rateToHome: expense.rate,
                    input: expense.input
                )
            }
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
