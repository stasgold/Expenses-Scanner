import Foundation
import SwiftData
import Testing
@testable import ExpensesScanner

/// Every schema version must open on today's app with nothing lost. Add a test per version.
@MainActor
struct MigrationTests {
    @Test func versionOneStoreOpensWithEverythingIntact() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }

        let ann = UUID()
        do {
            let schema = Schema(versionedSchema: ExpensesSchemaV1.self)
            let v1 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(v1)
            let trip = ExpensesSchemaV1.Trip(name: "Lisbon", homeCurrency: "EUR")
            context.insert(trip)
            let participant = ExpensesSchemaV1.Participant(name: "Ann", position: 0, colorIndex: 3)
            participant.uuid = ann
            context.insert(participant)
            trip.participants.append(participant)
            let expense = ExpensesSchemaV1.Expense(title: "Taxi", date: Date(), currency: "THB", kindRaw: "manual")
            expense.payerID = ann
            expense.rateToHome = "0.0256"
            expense.rateSourceRaw = "manual"
            context.insert(expense)
            trip.expenses.append(expense)
            let item = ExpensesSchemaV1.ExpenseItem(name: "Taxi", amount: 35_000, position: 0)
            context.insert(item)
            expense.items.append(item)
            let share = ExpensesSchemaV1.ItemShare(participantID: ann, weight: 1)
            context.insert(share)
            item.shares.append(share)
            try context.save()
        }

        let reopened = try ModelContainer.expenses(url: url)
        let trips = try reopened.mainContext.fetch(FetchDescriptor<Trip>())
        let trip = try #require(trips.first)
        #expect(trips.count == 1)
        #expect(trip.homeCurrency == "EUR")
        #expect(trip.orderedParticipants.map(\.name) == ["Ann"])
        #expect(trip.orderedParticipants.map(\.colorIndex) == [3])
        let expense = try #require(trip.orderedExpenses.first)
        #expect(expense.currency == "THB")
        #expect(expense.payerID == ann)
        #expect(expense.rate == Decimal(string: "0.0256"))
        #expect(expense.rateSource == .manual)
        #expect(expense.total == 35_000)
        #expect(Ledger(trip.snapshot).balances.map(\.net) == [0])
    }
}
