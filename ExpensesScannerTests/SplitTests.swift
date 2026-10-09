import Foundation
import Testing
@testable import ExpensesScanner

/// Small deterministic generator (SplitMix64) so the property tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct SplitTests {
    private let ann = UUID()
    private let ben = UUID()
    private let cleo = UUID()
    private var everyone: [UUID] { [ann, ben, cleo] }

    // MARK: allocate

    @Test func leftoverCentsGoToTheLargestRemainders() {
        #expect(Split.allocate(1000, weights: [1, 1, 1]) == [334, 333, 333])
        #expect(Split.allocate(1000, weights: [2, 1]) == [667, 333])
        #expect(Split.allocate(1, weights: [1, 1, 1]) == [1, 0, 0])
        #expect(Split.allocate(5, weights: [0, 1, 1]) == [0, 3, 2])
        #expect(Split.allocate(100, weights: [1, 3]) == [25, 75])
    }

    @Test func negativeTotalsSplitLikePositiveOnes() {
        #expect(Split.allocate(-1000, weights: [1, 1, 1]) == [-334, -333, -333])
    }

    @Test func nothingToSplitOrNobodyToSplitWith() {
        #expect(Split.allocate(0, weights: [1, 2]) == [0, 0])
        #expect(Split.allocate(100, weights: [0, 0]) == [0, 0])
        #expect(Split.allocate(100, weights: []) == [])
    }

    @Test func hugeAmountsAndWeightsDoNotOverflow() {
        let total: Int64 = 999_999_999_999_999
        let parts = Split.allocate(total, weights: [999_999_999_999, 1, 500_000_000_000])
        #expect(parts.reduce(0, +) == total)
        #expect(parts.allSatisfy { $0 >= 0 })
    }

    @Test func partsAlwaysAddUpAndStayWithinOneMinorUnit() {
        var random = SeededGenerator(state: 42)
        for _ in 0..<2000 {
            let total = Int64.random(in: -1_000_000_000...1_000_000_000, using: &random)
            let count = Int.random(in: 1...8, using: &random)
            var weights = (0..<count).map { _ in Int64.random(in: 0...1_000_000, using: &random) }
            if weights.allSatisfy({ $0 == 0 }) { weights[0] = 1 }

            let parts = Split.allocate(total, weights: weights)
            #expect(parts.reduce(0, +) == total)
            let weightSum = Decimal(weights.reduce(0, +))
            for (part, weight) in zip(parts, weights) {
                let exact = Decimal(total) * Decimal(weight) / weightSum
                let error = Decimal(part) - exact
                #expect(error > -1 && error < 1, "total \(total), weights \(weights)")
            }
        }
    }

    // MARK: shares

    @Test func oneLineSharedEqually() {
        let expense = ExpenseInput(lines: [LineInput(amount: 3000, shares: everyone.map { ShareInput(participant: $0, weight: 1) })])
        let shares = Split.shares(of: expense, participants: everyone)
        #expect(shares.owed == [ann: 1000, ben: 1000, cleo: 1000])
        #expect(shares.unassigned == 0)
    }

    @Test func weightsCountDouble() {
        let expense = ExpenseInput(lines: [LineInput(amount: 900, shares: [
            ShareInput(participant: ann, weight: 2), ShareInput(participant: ben, weight: 1),
        ])])
        #expect(Split.shares(of: expense, participants: everyone).owed == [ann: 600, ben: 300])
    }

    @Test func tipIsSharedInProportionToWhatEachPersonHad() {
        let expense = ExpenseInput(
            lines: [
                LineInput(amount: 2000, shares: [ShareInput(participant: ann, weight: 1)]),
                LineInput(amount: 1000, shares: [ShareInput(participant: ben, weight: 1)]),
                LineInput(amount: 900, shares: everyone.map { ShareInput(participant: $0, weight: 1) }),
            ],
            tip: 390
        )
        let shares = Split.shares(of: expense, participants: everyone)
        // Items: Ann 23.00, Ben 13.00, Cleo 3.00; the 10% tip follows.
        #expect(shares.owed == [ann: 2530, ben: 1430, cleo: 330])
        #expect(shares.total == expense.total)
        #expect(expense.total == 4290)
    }

    @Test func taxAddedOnTopCanBeSharedEqually() {
        let expense = ExpenseInput(
            lines: [
                LineInput(amount: 3000, shares: [ShareInput(participant: ann, weight: 1)]),
                LineInput(amount: 1000, shares: [ShareInput(participant: ben, weight: 1)]),
            ],
            tax: 100,
            taxIncluded: false,
            extrasMode: .equal
        )
        #expect(Split.shares(of: expense, participants: everyone).owed == [ann: 3050, ben: 1050])
    }

    @Test func includedTaxIsNeverAddedAgain() {
        let expense = ExpenseInput(
            lines: [LineInput(amount: 1190, shares: [ShareInput(participant: ann, weight: 1)])],
            tax: 190,
            taxIncluded: true
        )
        #expect(expense.total == 1190)
        #expect(Split.shares(of: expense, participants: everyone).owed == [ann: 1190])
    }

    @Test func discountsReduceEveryoneProportionally() {
        let expense = ExpenseInput(
            lines: [
                LineInput(amount: 1000, shares: [ShareInput(participant: ann, weight: 1)]),
                LineInput(amount: 3000, shares: [ShareInput(participant: ben, weight: 1)]),
            ],
            discount: 400
        )
        #expect(Split.shares(of: expense, participants: everyone).owed == [ann: 900, ben: 2700])
    }

    @Test func unassignedLinesKeepTheirPartOfTheExtras() {
        let expense = ExpenseInput(
            lines: [
                LineInput(amount: 1000, shares: []),
                LineInput(amount: 1000, shares: [ShareInput(participant: ann, weight: 1)]),
            ],
            tip: 200
        )
        let shares = Split.shares(of: expense, participants: everyone)
        #expect(shares.owed == [ann: 1100])
        #expect(shares.unassigned == 1100)
        #expect(shares.total == expense.total)
    }

    @Test func sharesForStrangersOrZeroWeightsLeaveTheLineUnassigned() {
        let expense = ExpenseInput(lines: [
            LineInput(amount: 500, shares: [ShareInput(participant: UUID(), weight: 1)]),
            LineInput(amount: 700, shares: [ShareInput(participant: ann, weight: 0)]),
        ])
        let shares = Split.shares(of: expense, participants: everyone)
        #expect(shares.owed.isEmpty)
        #expect(shares.unassigned == 1200)
    }

    @Test func leftoverCentFollowsTripOrder() {
        let expense = ExpenseInput(lines: [LineInput(amount: 100, shares: [
            ShareInput(participant: cleo, weight: 1), ShareInput(participant: ann, weight: 1), ShareInput(participant: ben, weight: 1),
        ])])
        #expect(Split.shares(of: expense, participants: everyone).owed == [ann: 34, ben: 33, cleo: 33])
    }

    // MARK: convert

    @Test func convertedSharesStillAddUpToTheConvertedTotal() throws {
        let rate = try #require(Decimal(string: "0.0256"))
        let shares = ExpenseShares(owed: [ann: 334, ben: 333, cleo: 333], unassigned: 0)
        let converted = Split.convert(shares, participants: everyone, from: "THB", to: "EUR", rate: rate)
        let total = Money.convert(1000, from: "THB", to: "EUR", rate: rate)
        #expect(total == 26)
        #expect(converted.total == total)
        #expect(converted.owed == [ann: 9, ben: 9, cleo: 8])
    }

    @Test func conversionKeepsTheUnassignedPart() throws {
        let rate = try #require(Decimal(string: "0.5"))
        let shares = ExpenseShares(owed: [ann: 1000], unassigned: 3000)
        let converted = Split.convert(shares, participants: everyone, from: "USD", to: "EUR", rate: rate)
        #expect(converted.owed == [ann: 500])
        #expect(converted.unassigned == 1500)
    }

    @Test func mixedSignsStillMatchTheConvertedTotal() throws {
        let rate = try #require(Decimal(string: "0.333"))
        let shares = ExpenseShares(owed: [ann: 1001, ben: -500], unassigned: 0)
        let converted = Split.convert(shares, participants: everyone, from: "USD", to: "EUR", rate: rate)
        #expect(converted.total == Money.convert(501, from: "USD", to: "EUR", rate: rate))
    }

    @Test func sameCurrencyIsUntouched() {
        let shares = ExpenseShares(owed: [ann: 1001], unassigned: 3)
        #expect(Split.convert(shares, participants: everyone, from: "EUR", to: "EUR", rate: 2) == shares)
    }
}
