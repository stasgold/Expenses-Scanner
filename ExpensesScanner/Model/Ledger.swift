import Foundation

/// What an expense is.
enum ExpenseKind: String, Codable {
    /// Typed in: a title, an amount, who shares it.
    case manual
    /// Scanned from a receipt, item by item.
    case receipt
    /// One person paying another back. The payer pays; the single line's share names who received it.
    case transfer
}

/// Where an expense's exchange rate came from.
enum RateSource: String, Codable {
    /// Fetched from the rate provider for the expense's date.
    case provider
    /// The newest cached rate, used while offline; replaced when a fresh one arrives.
    case cachedFallback
    /// Typed in by the user (e.g. their card's real rate). Never replaced automatically.
    case manual
}

struct ParticipantSnapshot: Equatable, Identifiable {
    var id: UUID
    var name: String
    var colorIndex: Int
}

/// One expense frozen at read time, in its own currency.
struct ExpenseSnapshot: Equatable, Identifiable {
    var id: UUID
    var title: String
    var kind: ExpenseKind
    var date: Date
    var currency: CurrencyCode
    var payer: UUID?
    /// One unit of `currency` in the trip's home currency; nil when not known yet.
    var rateToHome: Decimal?
    var input: ExpenseInput

    /// For a transfer: who received the money.
    var recipient: UUID? {
        kind == .transfer ? input.lines.first?.shares.first?.participant : nil
    }
}

/// A whole trip frozen at read time, so balances and shared text never mix two moments.
struct TripSnapshot: Equatable {
    var name: String
    var homeCurrency: CurrencyCode
    var participants: [ParticipantSnapshot]
    /// Newest first.
    var expenses: [ExpenseSnapshot]

    func participant(_ id: UUID?) -> ParticipantSnapshot? {
        guard let id else { return nil }
        return participants.first { $0.id == id }
    }
}

struct Balance: Equatable, Identifiable {
    var participant: UUID
    /// What they paid for others and themselves (assigned parts only), in the home currency.
    var paid: Int64
    /// Their share of everything, in the home currency.
    var owed: Int64

    /// Positive: others owe them. Negative: they owe.
    var net: Int64 { paid - owed }
    var id: UUID { participant }
}

/// "Ben pays Ann 15.00": one step towards everyone being even.
struct Transfer: Equatable, Hashable {
    var from: UUID
    var to: UUID
    var amount: Int64
}

/// Who paid, who owes, and how to settle, all in the trip's home currency.
struct Ledger: Equatable {
    /// In trip order, one per participant.
    var balances: [Balance]
    /// The fewest payments that make every balance 0.
    var transfers: [Transfer]
    /// Expenses left out because their rate to the home currency isn't known yet.
    var pendingRate: [UUID]
    /// Expenses left out because nobody is set as the payer.
    var missingPayer: [UUID]
    /// Home-currency amount on lines nobody is assigned to; left out until someone takes them.
    var unassigned: Int64
    /// Everything spent on the trip (transfers excluded), in the home currency.
    var spent: Int64

    var isSettled: Bool { transfers.isEmpty }

    init(_ trip: TripSnapshot) {
        let ids = trip.participants.map(\.id)
        let known = Set(ids)
        var paid: [UUID: Int64] = [:]
        var owed: [UUID: Int64] = [:]
        var pending: [UUID] = []
        var noPayer: [UUID] = []
        var unassigned: Int64 = 0
        var spent: Int64 = 0

        for expense in trip.expenses {
            var shares = Split.shares(of: expense.input, participants: ids)
            if expense.currency.uppercased() != trip.homeCurrency.uppercased() {
                guard let rate = expense.rateToHome else {
                    pending.append(expense.id)
                    continue
                }
                shares = Split.convert(shares, participants: ids, from: expense.currency, to: trip.homeCurrency, rate: rate)
            }
            guard let payer = expense.payer, known.contains(payer) else {
                noPayer.append(expense.id)
                continue
            }
            // The payer is credited with what others (and they) took on; unassigned lines wait.
            paid[payer, default: 0] += shares.assigned
            for (participant, amount) in shares.owed { owed[participant, default: 0] += amount }
            unassigned += shares.unassigned
            if expense.kind != .transfer { spent += shares.total }
        }

        let balances = ids.map { Balance(participant: $0, paid: paid[$0] ?? 0, owed: owed[$0] ?? 0) }
        self.balances = balances
        transfers = Ledger.settle(balances)
        pendingRate = pending
        missingPayer = noPayer
        self.unassigned = unassigned
        self.spent = spent
    }

    /**
     * Largest debtor pays largest creditor, again and again, until everyone is even: at most one payment
     * fewer than there are people with a balance. Ties keep trip order, so the answer is stable.
     */
    static func settle(_ balances: [Balance]) -> [Transfer] {
        let ordered = balances.enumerated().map { (order: $0.offset, participant: $0.element.participant, net: $0.element.net) }
        var creditors = ordered.filter { $0.net > 0 }
            .sorted { $0.net != $1.net ? $0.net > $1.net : $0.order < $1.order }
            .map { (participant: $0.participant, amount: $0.net) }
        var debtors = ordered.filter { $0.net < 0 }
            .sorted { $0.net != $1.net ? $0.net < $1.net : $0.order < $1.order }
            .map { (participant: $0.participant, amount: -$0.net) }

        var transfers: [Transfer] = []
        var debtor = 0
        var creditor = 0
        while debtor < debtors.count && creditor < creditors.count {
            let amount = min(debtors[debtor].amount, creditors[creditor].amount)
            transfers.append(Transfer(from: debtors[debtor].participant, to: creditors[creditor].participant, amount: amount))
            debtors[debtor].amount -= amount
            creditors[creditor].amount -= amount
            if debtors[debtor].amount == 0 { debtor += 1 }
            if creditors[creditor].amount == 0 { creditor += 1 }
        }
        return transfers
    }
}
