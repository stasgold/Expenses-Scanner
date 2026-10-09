import Foundation
import Testing
@testable import ExpensesScanner

/// Answers from memory, counts how often it was asked, and can pretend to be offline.
final class StubProvider: ExchangeRateProvider, @unchecked Sendable {
    let name: String
    /// Keyed by the day asked for, or "latest".
    var tables: [String: RateTable]
    var calls = 0
    var offline = false

    init(_ name: String, _ tables: [String: RateTable]) {
        self.name = name
        self.tables = tables
    }

    func table(base: CurrencyCode, day: String?) async throws -> RateTable {
        calls += 1
        guard !offline, let table = tables[day ?? "latest"], table.base == base.uppercased() else {
            throw RateError.badResponse
        }
        return table
    }
}

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

struct ExchangeRateTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: String, hour: Int = 12) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    private func eur(_ day: String, _ quotes: [String: String], source: String = "frankfurter", fetchedAt: Date = Date()) -> RateTable {
        RateTable(source: source, base: "EUR", day: day, quotes: quotes.mapValues { Decimal(string: $0)! }, fetchedAt: fetchedAt)
    }

    private func service(_ providers: [StubProvider], clock: TestClock, cache: RateCache = RateCache(url: nil)) -> RateService {
        RateService(providers: providers, cache: cache, calendar: utc, now: { clock.now })
    }

    // MARK: Providers

    @Test func readsFrankfurter() throws {
        let json = #"{"amount":1.0,"base":"EUR","date":"2026-10-08","rates":{"USD":1.0912,"THB":36.512,"JPY":162.33}}"#
        let table = try FrankfurterProvider.parse(Data(json.utf8), fetchedAt: Date())
        #expect(table.base == "EUR")
        #expect(table.day == "2026-10-08")
        #expect(table.units("USD") == Decimal(string: "1.0912"))
        #expect(table.units("eur") == 1)
        #expect(table.rate(from: "USD", to: "JPY") == ExchangeRates.tidy(Decimal(string: "162.33")! / Decimal(string: "1.0912")!))
    }

    @Test func readsCurrencyAPI() throws {
        let json = #"{"date":"2026-10-08","eur":{"usd":1.0912,"vnd":28512.5,"thb":36.512}}"#
        let table = try CurrencyAPIProvider.parse(Data(json.utf8), base: "EUR", fetchedAt: Date())
        #expect(table.day == "2026-10-08")
        #expect(table.units("VND") == Decimal(string: "28512.5"))
        #expect(table.rate(from: "VND", to: "EUR") == ExchangeRates.tidy(1 / Decimal(string: "28512.5")!))
    }

    @Test func unreadableResponsesThrow() {
        #expect(throws: (any Error).self) { try FrankfurterProvider.parse(Data("{}".utf8), fetchedAt: Date()) }
        #expect(throws: (any Error).self) { try CurrencyAPIProvider.parse(Data("<html>".utf8), base: "EUR", fetchedAt: Date()) }
    }

    @Test func ratesKeepTwelveDecimals() throws {
        let three = try #require(Decimal(string: "3"))
        let rate = ExchangeRates.tidy(1 / three)
        #expect(Money.rateText(rate) == "0.333333333333")
    }

    // MARK: Service

    @Test func pastDaysAreFetchedOnce() async throws {
        let frankfurter = StubProvider("frankfurter", ["2026-10-01": eur("2026-10-01", ["THB": "36.5"])])
        let rates = service([frankfurter], clock: TestClock(date("2026-10-09")))

        let first = try #require(await rates.rate(from: "THB", to: "EUR", on: date("2026-10-01", hour: 20)))
        let again = try #require(await rates.rate(from: "thb", to: "eur", on: date("2026-10-01")))
        #expect(first.rate == ExchangeRates.tidy(1 / Decimal(string: "36.5")!))
        #expect(first.source == .provider)
        #expect(first.day == "2026-10-01")
        #expect(again == first)
        #expect(frankfurter.calls == 1)
    }

    @Test func todaysRatesAreRefreshedAfterTwelveHours() async throws {
        let clock = TestClock(date("2026-10-09", hour: 8))
        let frankfurter = StubProvider("frankfurter", ["latest": eur("2026-10-09", ["USD": "1.09"], fetchedAt: clock.now)])
        let rates = service([frankfurter], clock: clock)

        _ = await rates.rate(from: "USD", to: "EUR", on: clock.now)
        clock.now = date("2026-10-09", hour: 14)
        _ = await rates.rate(from: "USD", to: "EUR", on: clock.now)
        #expect(frankfurter.calls == 1)

        clock.now = date("2026-10-09", hour: 21)
        _ = await rates.rate(from: "USD", to: "EUR", on: clock.now)
        #expect(frankfurter.calls == 2)
    }

    @Test func futureDaysUseTheLatestRates() async throws {
        let frankfurter = StubProvider("frankfurter", ["latest": eur("2026-10-09", ["USD": "1.09"])])
        let rates = service([frankfurter], clock: TestClock(date("2026-10-09")))
        let quote = try #require(await rates.rate(from: "USD", to: "EUR", on: date("2026-10-20")))
        #expect(quote.day == "2026-10-09")
    }

    @Test func weekendsGetTheLastBusinessDay() async throws {
        // Asked for Sunday 4 Oct; the ECB last published on Friday 2 Oct.
        let frankfurter = StubProvider("frankfurter", ["2026-10-04": eur("2026-10-02", ["USD": "1.08"])])
        let rates = service([frankfurter], clock: TestClock(date("2026-10-09")))
        let quote = try #require(await rates.rate(from: "USD", to: "EUR", on: date("2026-10-04")))
        #expect(quote.day == "2026-10-02")
        _ = await rates.rate(from: "USD", to: "EUR", on: date("2026-10-04"))
        #expect(frankfurter.calls == 1)
    }

    @Test func currenciesTheECBDoesNotPublishComeFromTheSecondProvider() async throws {
        let frankfurter = StubProvider("frankfurter", ["2026-10-01": eur("2026-10-01", ["USD": "1.09"])])
        let currencyAPI = StubProvider("currency-api", ["2026-10-01": eur("2026-10-01", ["VND": "28512.5"], source: "currency-api")])
        let rates = service([frankfurter, currencyAPI], clock: TestClock(date("2026-10-09")))

        let quote = try #require(await rates.rate(from: "VND", to: "EUR", on: date("2026-10-01")))
        #expect(quote.provider == "currency-api")
        #expect(quote.source == .provider)
        // The ECB table was fetched and kept too, so USD now comes from the cache.
        _ = await rates.rate(from: "USD", to: "EUR", on: date("2026-10-01"))
        #expect(frankfurter.calls == 1)
    }

    @Test func offlineUsesTheNearestSavedDay() async throws {
        let frankfurter = StubProvider("frankfurter", [
            "2026-10-01": eur("2026-10-01", ["THB": "36.5"]),
            "2026-09-20": eur("2026-09-20", ["THB": "37.0"]),
        ])
        let rates = service([frankfurter], clock: TestClock(date("2026-10-09")))
        _ = await rates.rate(from: "THB", to: "EUR", on: date("2026-10-01"))
        _ = await rates.rate(from: "THB", to: "EUR", on: date("2026-09-20"))

        frankfurter.offline = true
        let quote = try #require(await rates.rate(from: "THB", to: "EUR", on: date("2026-10-03")))
        #expect(quote.source == .cachedFallback)
        #expect(quote.day == "2026-10-01")
    }

    @Test func offlineWithNothingSavedHasNoRate() async {
        let frankfurter = StubProvider("frankfurter", [:])
        frankfurter.offline = true
        let rates = service([frankfurter], clock: TestClock(date("2026-10-09")))
        #expect(await rates.rate(from: "THB", to: "EUR", on: date("2026-10-01")) == nil)
    }

    @Test func savedRatesSurviveARestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "rates-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let table = eur("2026-10-01", ["THB": "36.512345678901"])
        await RateCache(url: url).store(table, base: "EUR", day: "2026-10-01")

        let reloaded = try #require(await RateCache(url: url).table(source: "frankfurter", base: "EUR", day: "2026-10-01"))
        #expect(reloaded.units("THB") == Decimal(string: "36.512345678901"))
        #expect(reloaded.day == "2026-10-01")
    }

    @Test func daysFollowTheCalendar() {
        #expect(ExchangeRates.day(date("2026-10-09", hour: 23), calendar: utc) == "2026-10-09")
        #expect(ExchangeRates.date(fromDay: "2026-10-09", calendar: utc) == date("2026-10-09"))
        #expect(ExchangeRates.date(fromDay: "nonsense", calendar: utc) == nil)
    }
}
