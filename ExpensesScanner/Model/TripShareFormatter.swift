import Foundation

extension TripSnapshot {
    func personName(_ participant: UUID?) -> String {
        self.participant(participant)?.name ?? "?"
    }

    /// "Dinner", or "Ben paid Ann" for a transfer.
    func title(of expense: ExpenseSnapshot) -> String {
        switch expense.kind {
        case .transfer:
            return L10n.transferTitle(personName(expense.payer), personName(expense.recipient))
        case .manual, .receipt:
            return expense.title.isEmpty ? L10n.untitledExpense : expense.title
        }
    }

    /// The expense's total in the home currency; nil while its rate is unknown.
    func homeTotal(of expense: ExpenseSnapshot) -> Int64? {
        if expense.currency.uppercased() == homeCurrency.uppercased() { return expense.input.total }
        guard let rate = expense.rateToHome else { return nil }
        return Money.convert(expense.input.total, from: expense.currency, to: homeCurrency, rate: rate)
    }
}

/**
 * Renders a trip as plain text, meant to be pasted into a chat or an email so everyone sees the same
 * numbers. Plain text travels everywhere and needs no app on the other side.
 */
enum TripShareFormatter {
    static func text(_ trip: TripSnapshot, locale: Locale = .current) -> String {
        let ledger = Ledger(trip)
        let home = trip.homeCurrency
        var lines: [String] = [trip.name.isEmpty ? L10n.untitledTrip : trip.name]
        lines.append(L10n.spentTotal(Money.format(ledger.spent, home, locale: locale)))

        lines.append("")
        lines.append(L10n.balancesIn(home))
        if ledger.balances.isEmpty {
            lines.append(L10n.shareNoPeople)
        }
        for balance in ledger.balances {
            lines.append("\(trip.personName(balance.participant)): \(Money.formatSigned(balance.net, home, locale: locale))")
        }

        lines.append("")
        lines.append(L10n.settleUp)
        if ledger.transfers.isEmpty {
            lines.append(L10n.everyoneEven)
        }
        for transfer in ledger.transfers {
            lines.append("\(trip.personName(transfer.from)) → \(trip.personName(transfer.to)): \(Money.format(transfer.amount, home, locale: locale))")
        }

        if !ledger.pendingRate.isEmpty {
            lines.append("")
            lines.append(L10n.pendingRateNotice(ledger.pendingRate.count))
        }

        if !trip.expenses.isEmpty {
            lines.append("")
            lines.append(L10n.expenses)
            // Oldest first reads like a diary of the trip.
            for expense in trip.expenses.reversed() {
                lines.append(line(for: expense, in: trip, locale: locale))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "12 Oct · Taxi · ฿350.00 (€9.10) · paid by Cleo"
    static func line(for expense: ExpenseSnapshot, in trip: TripSnapshot, locale: Locale = .current) -> String {
        var parts = [
            expense.date.formatted(.dateTime.day().month(.abbreviated).locale(locale)),
            trip.title(of: expense),
        ]
        var amount = Money.format(expense.input.total, expense.currency, locale: locale)
        if expense.currency.uppercased() != trip.homeCurrency.uppercased() {
            if let home = trip.homeTotal(of: expense) {
                amount += " (\(Money.format(home, trip.homeCurrency, locale: locale)))"
            } else {
                amount += " (\(L10n.noRateYet))"
            }
        }
        parts.append(amount)
        if expense.kind != .transfer {
            parts.append(L10n.paidBy(trip.personName(expense.payer)))
        }
        return parts.joined(separator: " · ")
    }
}
