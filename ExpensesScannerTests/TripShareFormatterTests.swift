import Foundation
import Testing
@testable import ExpensesScanner

struct TripShareFormatterTests {
    private let us = Locale(identifier: "en_US")
    private let ann = ParticipantSnapshot(id: UUID(), name: "Ann", colorIndex: 0)
    private let ben = ParticipantSnapshot(id: UUID(), name: "Ben", colorIndex: 1)

    private func expense(_ title: String, _ amount: Int64, paidBy payer: UUID, currency: CurrencyCode = "EUR", rate: Decimal? = nil, kind: ExpenseKind = .manual, among: [UUID]) -> ExpenseSnapshot {
        ExpenseSnapshot(
            id: UUID(),
            title: title,
            kind: kind,
            date: Date(timeIntervalSince1970: 1_791_500_000),
            currency: currency,
            payer: payer,
            rateToHome: rate,
            input: ExpenseInput(lines: [LineInput(amount: amount, shares: among.map { ShareInput(participant: $0, weight: 1) })])
        )
    }

    @Test func balancesTransfersAndEveryExpense() throws {
        let rate = try #require(Decimal(string: "1.2"))
        let trip = TripSnapshot(
            name: "Lisbon 2026",
            homeCurrency: "EUR",
            participants: [ann, ben],
            expenses: [
                expense("Taxi", 3000, paidBy: ben.id, currency: "GBP", rate: rate, among: [ann, ben].map(\.id)),
                expense("Dinner", 4000, paidBy: ann.id, among: [ann, ben].map(\.id)),
            ]
        )
        let text = TripShareFormatter.text(trip, locale: us)
        let lines = text.components(separatedBy: "\n")

        #expect(lines.first == "Lisbon 2026")
        // Dinner €40.00 + taxi £30.00 → €36.00. Ann paid 40, Ben paid 36, each had 38.
        #expect(lines.contains("Spent: €76.00"))
        #expect(lines.contains("Balances in EUR"))
        #expect(lines.contains("Ann: +€2.00"))
        #expect(lines.contains("Ben: -€2.00"))
        #expect(lines.contains("Ben → Ann: €2.00"))
        // Snapshots list the newest first (taxi); shared text reads oldest first.
        let dinner = try #require(lines.firstIndex { $0.contains("Dinner") })
        let taxi = try #require(lines.firstIndex { $0.contains("Taxi") })
        #expect(dinner < taxi)
        #expect(lines[taxi].hasSuffix("Taxi · £30.00 (€36.00) · paid by Ben"))
        #expect(lines[dinner].hasSuffix("Dinner · €40.00 · paid by Ann"))
    }

    @Test func transfersReadAsPaymentsAndMissingRatesAreFlagged() {
        let trip = TripSnapshot(
            name: "Tokyo",
            homeCurrency: "EUR",
            participants: [ann, ben],
            expenses: [
                expense("", 1000, paidBy: ben.id, kind: .transfer, among: [ann.id]),
                expense("Sushi", 6000, paidBy: ann.id, currency: "JPY", among: [ann, ben].map(\.id)),
            ]
        )
        let text = TripShareFormatter.text(trip, locale: us)
        #expect(text.contains("Ben paid Ann · €10.00"))
        #expect(!text.contains("Ben paid Ann · €10.00 · paid by"))
        #expect(text.contains("Sushi · ¥6,000 (no rate yet) · paid by Ann"))
        #expect(text.contains("1 expense has no exchange rate yet and isn’t counted."))
    }

    @Test func emptyTrip() {
        let text = TripShareFormatter.text(TripSnapshot(name: "", homeCurrency: "USD", participants: [], expenses: []), locale: us)
        #expect(text == """
        Untitled trip
        Spent: $0.00

        Balances in USD
        (nobody yet)

        Settle up
        Everyone is even.
        """)
    }
}
