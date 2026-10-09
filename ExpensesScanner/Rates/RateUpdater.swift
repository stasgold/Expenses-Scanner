import Foundation

/// Fills in exchange rates for a trip's expenses that are waiting for one.
@MainActor
enum RateUpdater {
    /// Changes whenever the set of expenses waiting for a rate changes; drives `.task(id:)` so a fetch
    /// runs after an expense is added or edited, and again each time the trip is opened.
    static func pendingKey(_ trip: Trip) -> String {
        let waiting = trip.orderedExpenses.filter(\.needsRate).map {
            "\($0.uuid.uuidString)|\($0.currency)|\(ExchangeRates.day($0.date))|\($0.rateSourceRaw ?? "-")"
        }
        return trip.homeCurrency + ":" + waiting.joined(separator: ",")
    }

    static func fill(_ trip: Trip, store: TripStore, service: RateService = .shared) async {
        let home = trip.homeCurrency
        let waiting = trip.orderedExpenses.filter(\.needsRate).map { (expense: $0, key: TripStore.RateKey($0), date: $0.date) }
        for entry in waiting {
            guard let quote = await service.rate(from: entry.key.currency, to: home, on: entry.date) else { continue }
            store.applyFetchedRate(quote, to: entry.expense, expected: entry.key, home: home)
        }
    }
}
