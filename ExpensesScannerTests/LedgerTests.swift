import Foundation
import Testing
@testable import ExpensesScanner

struct LedgerTests {
    private let ann = UUID()
    private let ben = UUID()
    private let cleo = UUID()

    private func trip(_ expenses: [ExpenseSnapshot], home: CurrencyCode = "EUR") -> TripSnapshot {
        TripSnapshot(
            name: "Lisbon",
            homeCurrency: home,
            participants: [
                ParticipantSnapshot(id: ann, name: "Ann", colorIndex: 0),
                ParticipantSnapshot(id: ben, name: "Ben", colorIndex: 1),
                ParticipantSnapshot(id: cleo, name: "Cleo", colorIndex: 2),
            ],
            expenses: expenses
        )
    }

    private func expense(
        _ amount: Int64,
        paidBy payer: UUID?,
        among people: [UUID],
        currency: CurrencyCode = "EUR",
        rate: Decimal? = nil,
        kind: ExpenseKind = .manual
    ) -> ExpenseSnapshot {
        ExpenseSnapshot(
            id: UUID(),
            title: "Expense",
            kind: kind,
            date: Date(),
            currency: currency,
            payer: payer,
            rateToHome: rate,
            input: ExpenseInput(lines: [LineInput(amount: amount, shares: people.map { ShareInput(participant: $0, weight: 1) })])
        )
    }

    private func net(_ ledger: Ledger) -> [UUID: Int64] {
        Dictionary(uniqueKeysWithValues: ledger.balances.map { ($0.participant, $0.net) })
    }

    @Test func balancesAndTheFewestTransfers() {
        let ledger = Ledger(trip([
            expense(3000, paidBy: ann, among: [ann, ben, cleo]),
            expense(900, paidBy: ben, among: [ann, ben, cleo]),
        ]))
        #expect(net(ledger) == [ann: 1700, ben: -400, cleo: -1300])
        #expect(ledger.balances.map(\.net).reduce(0, +) == 0)
        #expect(ledger.transfers == [
            Transfer(from: cleo, to: ann, amount: 1300),
            Transfer(from: ben, to: ann, amount: 400),
        ])
        #expect(ledger.spent == 3900)
        #expect(!ledger.isSettled)
    }

    @Test func recordedTransfersEvenThingsOut() {
        let paid = [
            expense(3000, paidBy: ann, among: [ann, ben, cleo]),
            expense(900, paidBy: ben, among: [ann, ben, cleo]),
        ]
        let settled = Ledger(trip(paid + [
            expense(1300, paidBy: cleo, among: [ann], kind: .transfer),
            expense(400, paidBy: ben, among: [ann], kind: .transfer),
        ]))
        #expect(net(settled) == [ann: 0, ben: 0, cleo: 0])
        #expect(settled.isSettled)
        // Paying each other back isn't spending.
        #expect(settled.spent == 3900)
    }

    @Test func foreignExpensesConvertAtTheirRate() throws {
        let rate = try #require(Decimal(string: "0.0256"))
        let ledger = Ledger(trip([expense(100_000, paidBy: ann, among: [ann, ben], currency: "THB", rate: rate)]))
        // 1,000.00 THB at 0.0256 = 25.60 EUR, half each.
        #expect(net(ledger) == [ann: 1280, ben: -1280, cleo: 0])
        #expect(ledger.spent == 2560)
    }

    @Test func expensesWithoutARateWait() {
        let pending = expense(5000, paidBy: ann, among: [ann, ben], currency: "JPY")
        let ledger = Ledger(trip([pending, expense(600, paidBy: ben, among: [ben, cleo])]))
        #expect(ledger.pendingRate == [pending.id])
        #expect(net(ledger) == [ann: 0, ben: 300, cleo: -300])
    }

    @Test func expensesWithoutAPayerAreLeftOut() {
        let orphan = expense(1000, paidBy: nil, among: [ann, ben])
        let stranger = expense(1000, paidBy: UUID(), among: [ann, ben])
        let ledger = Ledger(trip([orphan, stranger]))
        #expect(ledger.missingPayer == [orphan.id, stranger.id])
        #expect(net(ledger) == [ann: 0, ben: 0, cleo: 0])
    }

    @Test func unassignedLinesAreNotCreditedToThePayer() {
        var dinner = expense(1000, paidBy: ann, among: [ben])
        dinner.input.lines.append(LineInput(amount: 500, shares: []))
        let ledger = Ledger(trip([dinner]))
        #expect(net(ledger) == [ann: 1000, ben: -1000, cleo: 0])
        #expect(ledger.unassigned == 500)
        #expect(ledger.balances.map(\.net).reduce(0, +) == 0)
    }

    @Test func settlingIsStableOnTies() {
        let balances = [
            Balance(participant: ann, paid: 1000, owed: 0),
            Balance(participant: ben, paid: 1000, owed: 0),
            Balance(participant: cleo, paid: 0, owed: 2000),
        ]
        #expect(Ledger.settle(balances) == [
            Transfer(from: cleo, to: ann, amount: 1000),
            Transfer(from: cleo, to: ben, amount: 1000),
        ])
    }

    @Test func randomTripsAlwaysSettleToZero() {
        var random = SeededGenerator(state: 7)
        let people = [ann, ben, cleo, UUID(), UUID()]
        for _ in 0..<200 {
            let expenses = (0..<Int.random(in: 1...12, using: &random)).map { _ in
                let among = people.filter { _ in Bool.random(using: &random) }
                return expense(
                    Int64.random(in: 1...500_000, using: &random),
                    paidBy: people.randomElement(using: &random),
                    among: among.isEmpty ? [ann] : among
                )
            }
            var snapshot = trip(expenses)
            snapshot.participants = people.enumerated().map { ParticipantSnapshot(id: $1, name: "P\($0)", colorIndex: $0) }
            let ledger = Ledger(snapshot)
            #expect(ledger.balances.map(\.net).reduce(0, +) == 0)
            #expect(ledger.transfers.count <= people.count - 1)

            // Applying the suggested transfers leaves everyone even.
            var nets = net(ledger)
            for transfer in ledger.transfers {
                #expect(transfer.amount > 0)
                nets[transfer.from, default: 0] += transfer.amount
                nets[transfer.to, default: 0] -= transfer.amount
            }
            #expect(nets.values.allSatisfy { $0 == 0 })
        }
    }
}
