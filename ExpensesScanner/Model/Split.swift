import Foundation

/// How tax (when added on top), tip, service and discounts are shared out.
enum ExtrasMode: String, Codable, CaseIterable {
    /// In proportion to what each person had: the usual way.
    case proportional
    /// The same for everyone on the bill.
    case equal
}

/// One person's part of a line: 1 is a normal share, 2 counts double, 0 means not in it.
struct ShareInput: Equatable {
    var participant: UUID
    var weight: Int
}

/// One line of an expense: an item on a receipt, or the whole amount of a manual expense.
struct LineInput: Equatable {
    var amount: Int64
    /// Who had it; empty means nobody is assigned yet.
    var shares: [ShareInput]
}

/// Everything needed to work out who owes what for one expense, in the expense's own currency.
struct ExpenseInput: Equatable {
    var lines: [LineInput]
    var tax: Int64 = 0
    /// VAT-style tax already inside the item prices: shown, never added again.
    var taxIncluded = true
    var tip: Int64 = 0
    var service: Int64 = 0
    var discount: Int64 = 0
    var extrasMode: ExtrasMode = .proportional

    var itemsTotal: Int64 { lines.reduce(0) { $0 + $1.amount } }
    var extras: Int64 { (taxIncluded ? 0 : tax) + tip + service - discount }
    var total: Int64 { itemsTotal + extras }
}

/// What each person owes for one expense.
struct ExpenseShares: Equatable {
    /// Only people with a non-zero amount.
    var owed: [UUID: Int64]
    /// Lines nobody is assigned to yet, with their part of the extras.
    var unassigned: Int64

    var assigned: Int64 { owed.values.reduce(0, +) }
    var total: Int64 { assigned + unassigned }
}

enum Split {
    /**
     * Shares `total` out in proportion to `weights` so the parts always add up to `total` exactly.
     * Each part is its exact share rounded down; the minor units left over go to the largest remainders,
     * ties to the earlier index (the largest-remainder method). So 10.00 over three equal weights is
     * 3.34, 3.33, 3.33. A negative total is split as its magnitude, then negated.
     * Weights must not be negative. With no positive weight every part is 0.
     */
    static func allocate(_ total: Int64, weights: [Int64]) -> [Int64] {
        precondition(weights.allSatisfy { $0 >= 0 }, "Split weights must not be negative")
        let weightSum = weights.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard weightSum > 0, total != 0 else { return weights.map { _ in 0 } }

        let magnitude = total.magnitude
        var parts: [UInt64] = []
        var remainders: [UInt64] = []
        parts.reserveCapacity(weights.count)
        remainders.reserveCapacity(weights.count)
        for weight in weights {
            // Full-width arithmetic: amount × weight can exceed 64 bits when the weights are amounts too.
            let (quotient, remainder) = weightSum.dividingFullWidth(magnitude.multipliedFullWidth(by: UInt64(weight)))
            parts.append(quotient)
            remainders.append(remainder)
        }

        var leftover = magnitude - parts.reduce(0, +)
        let byRemainder = weights.indices.sorted {
            remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : $0 < $1
        }
        for index in byRemainder where leftover > 0 {
            parts[index] += 1
            leftover -= 1
        }
        return parts.map { total < 0 ? -Int64($0) : Int64($0) }
    }

    /**
     * What each person owes for `expense`. Each line is split by its shares; the extras follow
     * `extrasMode`. `participants` sets the order (the trip's), which decides who gets a leftover cent.
     * Shares naming someone outside `participants` are ignored.
     */
    static func shares(of expense: ExpenseInput, participants: [UUID]) -> ExpenseShares {
        let rank = Dictionary(participants.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var subtotals = [Int64](repeating: 0, count: participants.count)
        var involved = Set<Int>()
        var unassigned: Int64 = 0

        for line in expense.lines {
            let shares = line.shares
                .compactMap { share in rank[share.participant].map { (index: $0, weight: share.weight) } }
                .filter { $0.weight > 0 }
                .sorted { $0.index < $1.index }
            guard !shares.isEmpty else {
                unassigned += line.amount
                continue
            }
            let parts = allocate(line.amount, weights: shares.map { Int64($0.weight) })
            for (share, part) in zip(shares, parts) {
                subtotals[share.index] += part
                involved.insert(share.index)
            }
        }

        var owed = subtotals
        let extras = expense.extras
        if extras != 0 {
            let weights: [Int64]
            switch expense.extrasMode {
            case .proportional:
                // Unassigned lines carry their part of the extras until someone takes them.
                weights = subtotals.map { max($0, 0) } + [max(unassigned, 0)]
            case .equal:
                weights = participants.indices.map { involved.contains($0) ? Int64(1) : Int64(0) } + [Int64(0)]
            }
            if weights.contains(where: { $0 > 0 }) {
                let parts = allocate(extras, weights: weights)
                for index in participants.indices { owed[index] += parts[index] }
                unassigned += parts[participants.count]
            } else {
                unassigned += extras
            }
        }

        var result: [UUID: Int64] = [:]
        for (index, participant) in participants.enumerated() where owed[index] != 0 {
            result[participant] = owed[index]
        }
        return ExpenseShares(owed: result, unassigned: unassigned)
    }

    /**
     * The same shares in another currency. The total is converted once and split again by the original
     * amounts, so the converted parts still add up to the converted total: nobody gains or loses a cent
     * to rounding.
     */
    static func convert(
        _ shares: ExpenseShares,
        participants: [UUID],
        from: CurrencyCode,
        to: CurrencyCode,
        rate: Decimal
    ) -> ExpenseShares {
        guard from.uppercased() != to.uppercased() else { return shares }
        let amounts = participants.map { shares.owed[$0] ?? 0 } + [shares.unassigned]
        let total = Money.convert(shares.total, from: from, to: to, rate: rate)

        var converted: [Int64]
        if amounts.allSatisfy({ $0 >= 0 }) || amounts.allSatisfy({ $0 <= 0 }) {
            converted = allocate(total, weights: amounts.map { Int64($0.magnitude) })
        } else {
            // Mixed signs (a refund larger than someone's items): convert each part, then settle the
            // rounding difference on the largest one so the total still matches.
            converted = amounts.map { Money.convert($0, from: from, to: to, rate: rate) }
            let difference = total - converted.reduce(0, +)
            if difference != 0, let largest = converted.indices.max(by: { converted[$0].magnitude < converted[$1].magnitude }) {
                converted[largest] += difference
            }
        }

        var owed: [UUID: Int64] = [:]
        for (index, participant) in participants.enumerated() where converted[index] != 0 {
            owed[participant] = converted[index]
        }
        return ExpenseShares(owed: owed, unassigned: converted[participants.count])
    }
}
