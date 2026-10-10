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

@MainActor
struct ReceiptAndRateStoreTests {
    let container: ModelContainer
    let store: TripStore

    init() throws {
        container = try ModelContainer.expenses(inMemory: true)
        store = TripStore(context: container.mainContext)
    }

    private func quote(_ rate: String, day: String = "2026-10-08", source: RateSource = .provider) -> RateQuote {
        RateQuote(rate: Decimal(string: rate)!, day: day, source: source, fetchedAt: Date(), provider: "frankfurter")
    }

    @Test func scannedReceiptIsSavedLineByLine() throws {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "THB", people: ["Ann", "Ben"])
        let (ann, ben) = (trip.orderedParticipants[0].uuid, trip.orderedParticipants[1].uuid)
        var draft = ReceiptExpenseDraft(currency: "THB")
        draft.title = " Baan Thai "
        draft.payerID = ann
        draft.items = [
            ReceiptItemDraft(name: "Pad Thai", amount: 18_000, box: OCRBox(x: 0.1, y: 0.2, width: 0.5, height: 0.03), weights: [ann: 1]),
            ReceiptItemDraft(name: "Singha", amount: 24_000, quantity: 2, weights: [ann: 1, ben: 1]),
        ]
        draft.service = 4200
        draft.tax = 3234
        draft.taxIncluded = false
        draft.printedTotal = 49_434
        draft.rows = receiptRows("Pad Thai  180.00")

        let expense = store.addReceipt(to: trip, draft)
        #expect(expense.kind == .receipt)
        #expect(expense.title == "Baan Thai")
        #expect(expense.orderedItems.map(\.name) == ["Pad Thai", "Singha"])
        #expect(expense.orderedItems.first?.box == OCRBox(x: 0.1, y: 0.2, width: 0.5, height: 0.03))
        #expect(expense.total == 49_434)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ItemShare>()) == 3)

        // Back into the editor and out again, unchanged.
        let reopened = store.receiptDraft(for: expense)
        #expect(reopened.items.map(\.name) == draft.items.map(\.name))
        #expect(reopened.items.map(\.weights) == draft.items.map(\.weights))
        #expect(reopened.items.map(\.quantity) == [1, 2])
        #expect(reopened.input == draft.input)
        #expect(reopened.printedTotal == 49_434)
        #expect(reopened.rows == draft.rows)

        // Ann had the pad thai and half the beer; extras follow what each had.
        let ledger = Ledger(trip.snapshot)
        #expect(ledger.balances.map(\.net).reduce(0, +) == 0)
        #expect(ledger.balances[1].owed == Split.shares(of: draft.input, participants: [ann, ben]).owed[ben])
    }

    @Test func translationsAreKeptWithTheReceipt() throws {
        let trip = store.createTrip(name: "Kyoto", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0].uuid
        var draft = ReceiptExpenseDraft(currency: "JPY")
        draft.payerID = ann
        draft.sourceLanguage = "ja"
        draft.items = [ReceiptItemDraft(name: "自由席券", amount: 4960, weights: [ann: 1], translatedName: "Unreserved seat ticket", translatedLanguage: "en")]
        draft.rows = receiptRows("自由席券  ¥4,960")
        draft.rows[0].translation = "Unreserved seat ticket"
        draft.rows[0].translationLanguage = "en"

        let expense = store.addReceipt(to: trip, draft)
        #expect(expense.orderedItems.first?.translatedName == "Unreserved seat ticket")
        #expect(expense.sourceLanguage == "ja")

        let reopened = store.receiptDraft(for: expense)
        #expect(reopened.items.first?.translatedName == "Unreserved seat ticket")
        #expect(reopened.items.first?.translatedLanguage == "en")
        #expect(reopened.rows.first?.translation == "Unreserved seat ticket")
        #expect(reopened.sourceLanguage == "ja")

        store.setTargetLanguage(trip, "ru")
        #expect(trip.targetLanguage == "ru")
        store.setTargetLanguage(trip, nil)
        #expect(trip.targetLanguage == nil)
    }

    @Test func aReceiptWithOnlyItsTotalReadSplitsTheTotal() throws {
        let trip = store.createTrip(name: "Tokyo", homeCurrency: "JPY", people: ["Ann", "Ben"])
        let people = trip.orderedParticipants.map(\.uuid)
        var parsed = ParsedReceipt()
        parsed.total = 17_500
        parsed.tax = 1590
        parsed.taxIncluded = false
        parsed.tip = 500
        var draft = ReceiptExpenseDraft(parsed: parsed, rows: [], currency: "JPY", date: Date(), payer: people[0], participants: people, photo: nil)
        #expect(draft.items.map(\.amount) == [17_500])
        #expect(draft.items.first?.weights == [people[0]: 1, people[1]: 1])
        #expect(draft.input.total == 17_500)
        #expect(draft.mismatch == 0)
        #expect(draft.isValid)

        // Lines removed by hand: still saveable, as the total.
        draft.items = []
        #expect(draft.isValid)
        draft.useTotalAsOneLine(sharedBy: [people[1]: 1])
        let expense = store.addReceipt(to: trip, draft)
        #expect(expense.total == 17_500)
        #expect(Ledger(trip.snapshot).balances.map(\.net) == [17_500, -17_500])
    }

    @Test func aReceiptWithUnreadLinesIsSavedAtItsPrintedTotal() throws {
        let trip = store.createTrip(name: "Kyoto", homeCurrency: "JPY", people: ["Ann", "Ben", "Cat"])
        let people = trip.orderedParticipants.map(\.uuid)
        var draft = ReceiptExpenseDraft(currency: "JPY")
        draft.payerID = people[0]
        draft.items = [
            ReceiptItemDraft(name: "Sandwich", amount: 556, weights: [people[0]: 1]),
            ReceiptItemDraft(name: "Beer", amount: 414, weights: [people[1]: 1]),
        ]
        draft.tax = 80
        draft.taxIncluded = false
        draft.printedTotal = 1100
        #expect(draft.mismatch == 50)

        // The difference becomes a line for everyone who had something; Cat had nothing.
        draft.settleToPrintedTotal()
        #expect(draft.items.last?.name == L10n.totalDifference)
        #expect(draft.items.last?.amount == 50)
        #expect(draft.items.last?.weights == [people[0]: 1, people[1]: 1])
        #expect(draft.input.total == 1100)
        #expect(draft.mismatch == 0)

        // Edited and saved again: the same line is adjusted, not a second one added.
        draft.items[1].amount = 434
        draft.settleToPrintedTotal()
        #expect(draft.items.map(\.amount) == [556, 434, 30])
        draft.items[1].amount = 464
        draft.settleToPrintedTotal()
        #expect(draft.items.map(\.amount) == [556, 464])

        draft.items[1].amount = 414
        draft.settleToPrintedTotal()
        let expense = store.addReceipt(to: trip, draft)
        #expect(expense.total == 1100)
    }

    @Test func editingAReceiptReplacesItsLines() throws {
        let trip = store.createTrip(name: "Lisbon", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0].uuid
        var draft = ReceiptExpenseDraft(currency: "EUR")
        draft.payerID = ann
        draft.items = [ReceiptItemDraft(name: "A", amount: 100, weights: [ann: 1]), ReceiptItemDraft(name: "B", amount: 200, weights: [ann: 1])]
        let expense = store.addReceipt(to: trip, draft)

        var edited = store.receiptDraft(for: expense)
        edited.items.removeFirst()
        edited.items[0].amount = 250
        store.updateReceipt(expense, edited)
        #expect(expense.orderedItems.map(\.amount) == [250])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ExpenseItem>()) == 1)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ItemShare>()) == 1)
    }

    @Test func fetchedRatesFillWaitingExpenses() {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let expense = store.addExpense(to: trip, ManualExpenseDraft(title: "Taxi", amount: 35_000, currency: "THB", payerID: ann.uuid, weights: [ann.uuid: 1]))
        #expect(expense.needsRate)

        #expect(store.applyFetchedRate(quote("0.0274"), to: expense, expected: TripStore.RateKey(expense), home: "EUR"))
        #expect(expense.rate == Decimal(string: "0.0274"))
        #expect(expense.rateSource == .provider)
        #expect(!expense.needsRate)
        #expect(Ledger(trip.snapshot).spent == 959)
    }

    @Test func fetchedRatesNeverOverrideTheUsersOwn() throws {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let typed = try #require(Decimal(string: "0.0280"))
        let expense = store.addExpense(to: trip, ManualExpenseDraft(title: "Taxi", amount: 35_000, currency: "THB", payerID: ann.uuid, weights: [ann.uuid: 1], rateToHome: typed))
        #expect(!expense.needsRate)
        #expect(!store.applyFetchedRate(quote("0.0274"), to: expense, expected: TripStore.RateKey(expense), home: "EUR"))
        #expect(expense.rate == typed)
    }

    @Test func aRateForWhatTheExpenseUsedToBeIsIgnored() {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let expense = store.addExpense(to: trip, ManualExpenseDraft(title: "Taxi", amount: 35_000, currency: "THB", payerID: ann.uuid, weights: [ann.uuid: 1]))
        let asked = TripStore.RateKey(expense)

        // The user switched the expense to yen while the baht rate was on its way.
        var draft = store.draft(for: expense)
        draft.currency = "JPY"
        store.updateExpense(expense, draft)
        #expect(!store.applyFetchedRate(quote("0.0274"), to: expense, expected: asked, home: "EUR"))
        #expect(expense.rate == nil)
        // …or changed the trip's currency.
        #expect(!store.applyFetchedRate(quote("0.0061"), to: expense, expected: TripStore.RateKey(expense), home: "USD"))
    }

    @Test func anOlderStandInNeverReplacesAFreshRate() {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let expense = store.addExpense(to: trip, ManualExpenseDraft(title: "Taxi", amount: 35_000, currency: "THB", payerID: ann.uuid, weights: [ann.uuid: 1]))
        let key = TripStore.RateKey(expense)

        #expect(store.applyFetchedRate(quote("0.0270", source: .cachedFallback), to: expense, expected: key, home: "EUR"))
        #expect(expense.needsRate)
        #expect(Ledger(trip.snapshot).pendingRate.isEmpty)
        #expect(trip.snapshot.expenses[0].rateIsApproximate)

        #expect(store.applyFetchedRate(quote("0.0274"), to: expense, expected: key, home: "EUR"))
        #expect(!store.applyFetchedRate(quote("0.0270", source: .cachedFallback), to: expense, expected: key, home: "EUR"))
        #expect(expense.rate == Decimal(string: "0.0274"))
    }

    @Test func movingAnExpenseToAnotherDayFetchesItsRateAgain() {
        let trip = store.createTrip(name: "Bangkok", homeCurrency: "EUR", people: ["Ann"])
        let ann = trip.orderedParticipants[0]
        let expense = store.addExpense(to: trip, ManualExpenseDraft(title: "Taxi", amount: 35_000, currency: "THB", payerID: ann.uuid, weights: [ann.uuid: 1]))
        store.applyFetchedRate(quote("0.0274"), to: expense, expected: TripStore.RateKey(expense), home: "EUR")

        var sameDay = store.draft(for: expense)
        sameDay.amount = 40_000
        store.updateExpense(expense, sameDay)
        #expect(expense.rate == Decimal(string: "0.0274"))

        var otherDay = store.draft(for: expense)
        otherDay.date = expense.date.addingTimeInterval(-3 * 86_400)
        store.updateExpense(expense, otherDay)
        #expect(expense.rate == nil)
        #expect(expense.needsRate)
    }
}
