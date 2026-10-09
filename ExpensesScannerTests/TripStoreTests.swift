import Foundation
import SwiftData
import Testing
@testable import ExpensesScanner

@MainActor
struct TripStoreTests {
    let container: ModelContainer
    let store: TripStore

    init() throws {
        container = try ModelContainer.expenses(inMemory: true)
        store = TripStore(context: container.mainContext)
    }

    private func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
        try container.mainContext.fetchCount(FetchDescriptor<T>())
    }

    private func draft(_ amount: Int64, paidBy payer: Participant, weights: [Participant: Int], currency: CurrencyCode = "EUR", rate: Decimal? = nil) -> ManualExpenseDraft {
        ManualExpenseDraft(
            title: "Dinner",
            amount: amount,
            currency: currency,
            date: Date(),
            payerID: payer.uuid,
            weights: Dictionary(uniqueKeysWithValues: weights.map { ($0.key.uuid, $0.value) }),
            rateToHome: rate
        )
    }

    @Test func createTripTrimsNamesAndSkipsBlankPeople() {
        let trip = store.createTrip(name: "  Lisbon ", homeCurrency: "eur", people: ["Ann", "  ", " Ben "])
        #expect(trip.name == "Lisbon")
        #expect(trip.homeCurrency == "EUR")
        #expect(trip.orderedParticipants.map(\.name) == ["Ann", "Ben"])
        #expect(trip.orderedParticipants.map(\.colorIndex) == [0, 1])
    }

    @Test func manualExpenseFlowsIntoBalances() throws {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann", "Ben", "Cleo"])
        let people = trip.orderedParticipants
        let (ann, ben, cleo) = (people[0], people[1], people[2])

        let expense = store.addExpense(to: trip, draft(3000, paidBy: ann, weights: [ann: 1, ben: 1, cleo: 1]))
        #expect(expense.kind == .manual)
        #expect(expense.orderedItems.count == 1)
        #expect(expense.total == 3000)

        let ledger = Ledger(trip.snapshot)
        #expect(ledger.balances.map(\.net) == [2000, -1000, -1000])
        #expect(try count(ItemShare.self) == 3)
    }

    @Test func editingAnExpenseReplacesItsShares() throws {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann", "Ben", "Cleo"])
        let people = trip.orderedParticipants
        let expense = store.addExpense(to: trip, draft(3000, paidBy: people[0], weights: [people[0]: 1, people[1]: 1, people[2]: 1]))

        var edited = store.draft(for: expense)
        #expect(edited.amount == 3000)
        #expect(edited.weights == [people[0].uuid: 1, people[1].uuid: 1, people[2].uuid: 1])
        edited.amount = 900
        edited.weights = [people[1].uuid: 2, people[2].uuid: 1]
        edited.payerID = people[1].uuid
        store.updateExpense(expense, edited)

        #expect(try count(ItemShare.self) == 2)
        #expect(try count(ExpenseItem.self) == 1)
        #expect(Ledger(trip.snapshot).balances.map(\.net) == [0, 300, -300])
    }

    @Test func foreignExpenseKeepsTheTypedRate() throws {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann", "Ben"])
        let people = trip.orderedParticipants
        let rate = try #require(Decimal(string: "0.0256"))
        let expense = store.addExpense(to: trip, draft(100_000, paidBy: people[0], weights: [people[0]: 1, people[1]: 1], currency: "thb", rate: rate))
        #expect(expense.currency == "THB")
        #expect(expense.rate == rate)
        #expect(expense.rateSource == .manual)
        #expect(store.draft(for: expense).rateToHome == rate)
        #expect(Ledger(trip.snapshot).balances.map(\.net) == [1280, -1280])
    }

    @Test func changingTheCurrencyDropsAFetchedRate() throws {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let expense = store.addExpense(to: trip, draft(1000, paidBy: ann, weights: [ann: 1], currency: "THB"))
        // As if stage 2 had fetched it.
        let fetched = try #require(Decimal(string: "0.0256"))
        expense.rate = fetched
        expense.rateSource = .provider

        var sameCurrency = store.draft(for: expense)
        sameCurrency.amount = 2000
        store.updateExpense(expense, sameCurrency)
        #expect(expense.rateSource == .provider)

        var otherCurrency = store.draft(for: expense)
        otherCurrency.currency = "JPY"
        store.updateExpense(expense, otherCurrency)
        #expect(expense.rate == nil)
        #expect(expense.rateSource == nil)
        #expect(Ledger(trip.snapshot).pendingRate == [expense.uuid])
    }

    @Test func changingTheHomeCurrencyDropsEveryRate() throws {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let rate = try #require(Decimal(string: "0.0256"))
        let expense = store.addExpense(to: trip, draft(1000, paidBy: ann, weights: [ann: 1], currency: "THB", rate: rate))

        store.updateTrip(trip, name: "Bangkok", homeCurrency: "EUR")
        #expect(expense.rate == rate)

        store.updateTrip(trip, name: "Bangkok", homeCurrency: "usd")
        #expect(trip.homeCurrency == "USD")
        #expect(expense.rate == nil)
        #expect(Ledger(trip.snapshot).pendingRate == [expense.uuid])
    }

    @Test func peopleWhoPaidCannotBeRemoved() throws {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann", "Ben", "Cleo"])
        let people = trip.orderedParticipants
        store.addExpense(to: trip, draft(3000, paidBy: people[0], weights: [people[0]: 1, people[1]: 1, people[2]: 1]))

        #expect(!store.canDelete(people[0]))
        store.deleteParticipant(people[0])
        #expect(trip.orderedParticipants.count == 3)

        #expect(store.canDelete(people[2]))
        store.deleteParticipant(people[2])
        #expect(trip.orderedParticipants.map(\.name) == ["Ann", "Ben"])
        #expect(try count(ItemShare.self) == 2)
        #expect(Ledger(trip.snapshot).balances.map(\.net) == [1500, -1500])
    }

    @Test func peopleInATransferCannotBeRemoved() {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann", "Ben"])
        let people = trip.orderedParticipants
        store.recordTransfer(in: trip, Transfer(from: people[0].uuid, to: people[1].uuid, amount: 500))
        #expect(!store.canDelete(people[0]))
        #expect(!store.canDelete(people[1]))
    }

    @Test func markingATransferPaidSettlesTheTrip() {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann", "Ben", "Cleo"])
        let people = trip.orderedParticipants
        store.addExpense(to: trip, draft(3000, paidBy: people[0], weights: [people[0]: 1, people[1]: 1, people[2]: 1]))

        for transfer in Ledger(trip.snapshot).transfers {
            store.recordTransfer(in: trip, transfer)
        }
        let ledger = Ledger(trip.snapshot)
        #expect(ledger.isSettled)
        #expect(ledger.balances.allSatisfy { $0.net == 0 })
        #expect(ledger.spent == 3000)
        #expect(trip.orderedExpenses.filter { $0.kind == .transfer }.count == 2)
    }

    @Test func deletingATripDeletesEverythingInIt() throws {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann", "Ben"])
        let people = trip.orderedParticipants
        store.addExpense(to: trip, draft(1000, paidBy: people[0], weights: [people[0]: 1, people[1]: 1]))
        store.deleteTrip(trip)
        #expect(try count(Trip.self) == 0)
        #expect(try count(Participant.self) == 0)
        #expect(try count(Expense.self) == 0)
        #expect(try count(ExpenseItem.self) == 0)
        #expect(try count(ItemShare.self) == 0)
    }

    @Test func deletingAnExpenseKeepsTheRest() throws {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let first = store.addExpense(to: trip, draft(1000, paidBy: ann, weights: [ann: 1]))
        store.addExpense(to: trip, draft(2000, paidBy: ann, weights: [ann: 1]))
        store.deleteExpense(first)
        #expect(trip.orderedExpenses.map(\.total) == [2000])
        #expect(try count(ExpenseItem.self) == 1)
    }
}
