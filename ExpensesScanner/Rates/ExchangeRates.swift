import Foundation

/// One day's rates from one source: how many units of each currency one unit of `base` buys.
struct RateTable: Codable, Equatable {
    /// Which provider it came from, e.g. "frankfurter".
    var source: String
    var base: CurrencyCode
    /// The day the rates are for, as the provider reports it ("2026-10-09"). On weekends and holidays it
    /// is the last business day before the day asked for.
    var day: String
    /// Units per one `base`, as exact decimal text so no digit is lost on the way to disk and back.
    var quotes: [String: String]
    var fetchedAt: Date

    init(source: String, base: CurrencyCode, day: String, quotes: [String: Decimal], fetchedAt: Date) {
        self.source = source
        self.base = base.uppercased()
        self.day = day
        self.quotes = quotes.reduce(into: [String: String]()) { $0[$1.key.uppercased()] = Money.rateText($1.value) }
        self.fetchedAt = fetchedAt
    }

    /// Units of `currency` per one `base`; 1 for the base itself.
    func units(_ currency: CurrencyCode) -> Decimal? {
        let code = currency.uppercased()
        if code == base { return 1 }
        return Money.rate(fromText: quotes[code]).flatMap { $0 > 0 ? $0 : nil }
    }

    /// One unit of `from` in `to`, through the base: (base→to) / (base→from).
    func rate(from: CurrencyCode, to: CurrencyCode) -> Decimal? {
        guard let fromUnits = units(from), let toUnits = units(to) else { return nil }
        return ExchangeRates.tidy(toUnits / fromUnits)
    }
}

/// A rate ready to put on an expense.
struct RateQuote: Equatable {
    /// One unit of the expense's currency in the home currency.
    var rate: Decimal
    /// The day the rate is for ("2026-10-09").
    var day: String
    /// `.provider` when fetched for this day; `.cachedFallback` when an older saved rate stands in while offline.
    var source: RateSource
    var fetchedAt: Date
    /// Which provider published it.
    var provider: String
}

/// A source of daily exchange rates.
protocol ExchangeRateProvider: Sendable {
    var name: String { get }
    /// Rates against `base` for `day` ("yyyy-MM-dd"), or the latest published when `day` is nil.
    func table(base: CurrencyCode, day: String?) async throws -> RateTable
}

enum RateError: Error {
    case badResponse
    case unreadable
}

/// Downloads `url`; throws unless the server answers 2xx. Swapped out in tests.
typealias RateFetch = @Sendable (URL) async throws -> Data

enum ExchangeRates {
    static let defaultFetch: RateFetch = { url in
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RateError.badResponse
        }
        return data
    }

    /// Rates keep 12 decimal places: plenty for VND→EUR, and short enough to read.
    static func tidy(_ rate: Decimal) -> Decimal {
        var input = rate
        var result = Decimal()
        NSDecimalRound(&result, &input, 12, .plain)
        return result
    }

    /// "2026-10-09" for a date in the given calendar (the user's, by default).
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Noon on that day in the given calendar, so time zones never move it to a neighbouring day.
    static func date(fromDay day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// JSON numbers as exact decimals: goes through the number's shortest text, never through Double maths.
    static func decimal(_ value: Any) -> Decimal? {
        if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() {
            return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let text = value as? String {
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }
}

// MARK: - Providers

/**
 * Frankfurter: European Central Bank reference rates, about 30 major currencies, every business day
 * since 1999. Free, no key. https://frankfurter.dev
 */
struct FrankfurterProvider: ExchangeRateProvider {
    let name = "frankfurter"
    var fetch: RateFetch = ExchangeRates.defaultFetch

    func table(base: CurrencyCode, day: String?) async throws -> RateTable {
        guard let url = URL(string: "https://api.frankfurter.dev/v1/\(day ?? "latest")?base=\(base.uppercased())") else {
            throw RateError.badResponse
        }
        return try Self.parse(try await fetch(url), fetchedAt: Date())
    }

    /// `{"amount":1.0,"base":"EUR","date":"2026-10-09","rates":{"USD":1.0912,…}}`
    static func parse(_ data: Data, fetchedAt: Date) throws -> RateTable {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = object["base"] as? String,
              let day = object["date"] as? String,
              let rates = object["rates"] as? [String: Any]
        else { throw RateError.unreadable }
        let quotes = rates.compactMapValues(ExchangeRates.decimal)
        guard !quotes.isEmpty else { throw RateError.unreadable }
        return RateTable(source: "frankfurter", base: base, day: day, quotes: quotes, fetchedAt: fetchedAt)
    }
}

/**
 * fawazahmed0's currency-api: about 200 currencies (including ones the ECB doesn't publish, such as VND),
 * daily since March 2024, served from jsDelivr with a Cloudflare mirror. Free, no key, no rate limits.
 * https://github.com/fawazahmed0/exchange-api
 */
struct CurrencyAPIProvider: ExchangeRateProvider {
    let name = "currency-api"
    var fetch: RateFetch = ExchangeRates.defaultFetch

    func table(base: CurrencyCode, day: String?) async throws -> RateTable {
        let version = day ?? "latest"
        let code = base.lowercased()
        let urls = [
            "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(version)/v1/currencies/\(code).min.json",
            "https://\(version).currency-api.pages.dev/v1/currencies/\(code).min.json",
        ].compactMap(URL.init(string:))
        var lastError: Error = RateError.badResponse
        for url in urls {
            do {
                return try Self.parse(try await fetch(url), base: base, fetchedAt: Date())
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// `{"date":"2026-10-09","eur":{"usd":1.0912,"thb":38.1,…}}`
    static func parse(_ data: Data, base: CurrencyCode, fetchedAt: Date) throws -> RateTable {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let day = object["date"] as? String,
              let rates = object[base.lowercased()] as? [String: Any]
        else { throw RateError.unreadable }
        let quotes = rates.compactMapValues(ExchangeRates.decimal).filter { $0.value > 0 }
        guard !quotes.isEmpty else { throw RateError.unreadable }
        return RateTable(source: "currency-api", base: base, day: day, quotes: quotes, fetchedAt: fetchedAt)
    }
}

// MARK: - Cache

/**
 * Every rate table fetched, saved to one small JSON file in Caches. Disposable: losing it only costs a
 * refetch, because each expense keeps its own copy of the rate it uses.
 */
actor RateCache {
    private let url: URL?
    private var entries: [String: RateTable]?
    private let limit = 300

    /// `url: nil` keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "exchange-rates.json")
    }

    func table(source: String, base: CurrencyCode, day: String) -> RateTable? {
        load()[Self.key(source, base, day)]
    }

    func store(_ table: RateTable, base: CurrencyCode, day: String) {
        var entries = load()
        entries[Self.key(table.source, base, day)] = table
        if entries.count > limit {
            for key in entries.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt }).prefix(entries.count - limit).map(\.key) {
                entries.removeValue(forKey: key)
            }
        }
        self.entries = entries
        save(entries)
    }

    func all() -> [RateTable] {
        Array(load().values)
    }

    private func load() -> [String: RateTable] {
        if let entries { return entries }
        var loaded: [String: RateTable] = [:]
        if let url, let data = try? Data(contentsOf: url) {
            loaded = (try? JSONDecoder().decode([String: RateTable].self, from: data)) ?? [:]
        }
        entries = loaded
        return loaded
    }

    private func save(_ entries: [String: RateTable]) {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func key(_ source: String, _ base: CurrencyCode, _ day: String) -> String {
        "\(source)|\(base.uppercased())|\(day)"
    }
}

// MARK: - Service

/**
 * Finds the rate for an expense: its currency into the trip's home currency, for the expense's day.
 *
 * Cache first. Past days never change, so they are fetched once; today's rates are refreshed after
 * 12 hours. Providers are tried in order until one publishes the currency. Offline, the saved rate for
 * the nearest day stands in (`.cachedFallback`) until a fresh one can be fetched.
 */
actor RateService {
    static let shared = RateService(
        providers: [FrankfurterProvider(), CurrencyAPIProvider()],
        cache: RateCache(url: RateCache.defaultURL)
    )

    private let providers: [any ExchangeRateProvider]
    private let cache: RateCache
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let todayLifetime: TimeInterval = 12 * 60 * 60

    init(
        providers: [any ExchangeRateProvider],
        cache: RateCache,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.cache = cache
        self.calendar = calendar
        self.now = now
    }

    /// One unit of `from` in `to` on `date`'s day; nil when no rate is known and none can be fetched.
    func rate(from: CurrencyCode, to: CurrencyCode, on date: Date) async -> RateQuote? {
        let from = from.uppercased()
        let to = to.uppercased()
        let today = ExchangeRates.day(now(), calendar: calendar)
        let wanted = ExchangeRates.day(date, calendar: calendar)
        // Today's and future expenses use the latest published rates.
        let isCurrent = wanted >= today
        let day = isCurrent ? today : wanted

        for provider in providers {
            if let table = await cache.table(source: provider.name, base: to, day: day),
               !isCurrent || now().timeIntervalSince(table.fetchedAt) < todayLifetime,
               let quote = makeQuote(table, from: from, to: to, source: .provider) {
                return quote
            }
        }
        for provider in providers {
            guard let table = try? await provider.table(base: to, day: isCurrent ? nil : day) else { continue }
            await cache.store(table, base: to, day: day)
            if let quote = makeQuote(table, from: from, to: to, source: .provider) {
                return quote
            }
        }
        return await nearestCached(from: from, to: to, day: day)
    }

    /// The saved rate for the day closest to `day`, from any provider and any base that has both currencies.
    private func nearestCached(from: CurrencyCode, to: CurrencyCode, day: String) async -> RateQuote? {
        let target = ExchangeRates.date(fromDay: day, calendar: calendar) ?? now()
        let candidates = await cache.all().compactMap { table -> (table: RateTable, distance: TimeInterval)? in
            guard table.rate(from: from, to: to) != nil,
                  let tableDate = ExchangeRates.date(fromDay: table.day, calendar: calendar)
            else { return nil }
            return (table, abs(tableDate.timeIntervalSince(target)))
        }
        guard let best = candidates.min(by: { $0.distance != $1.distance ? $0.distance < $1.distance : $0.table.fetchedAt > $1.table.fetchedAt })
        else { return nil }
        return makeQuote(best.table, from: from, to: to, source: .cachedFallback)
    }

    private func makeQuote(_ table: RateTable, from: CurrencyCode, to: CurrencyCode, source: RateSource) -> RateQuote? {
        guard let rate = table.rate(from: from, to: to) else { return nil }
        return RateQuote(rate: rate, day: table.day, source: source, fetchedAt: table.fetchedAt, provider: table.source)
    }
}
