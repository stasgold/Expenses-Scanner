import Foundation
import Testing
@testable import ExpensesScanner

struct MoneyTests {
    private let us = Locale(identifier: "en_US")

    @Test(arguments: [("EUR", 2), ("usd", 2), ("THB", 2), ("JPY", 0), ("VND", 0), ("KRW", 0), ("KWD", 3), ("BHD", 3)])
    func minorDigitsFollowISO4217(currency: String, digits: Int) {
        #expect(Money.minorDigits(currency) == digits)
    }

    @Test(arguments: [
        ("12", "EUR", Int64(1200)),
        ("12.5", "EUR", 1250),
        ("12,50", "EUR", 1250),
        ("12.", "EUR", 1200),
        (".5", "EUR", 50),
        ("1 234,56", "EUR", 123_456),
        ("1,234.56", "USD", 123_456),
        ("1.234,56", "EUR", 123_456),
        ("1,234", "USD", 123_400),
        ("1.500", "EUR", 150_000),
        ("1.234.567", "EUR", 123_456_700),
        ("0,500", "EUR", 50),
        ("0.125", "EUR", 13),
        ("€ 8", "EUR", 800),
        ("1200", "JPY", 1200),
        ("1,200", "JPY", 1200),
        ("1.5", "JPY", 2),
        ("1.250", "KWD", 1250),
        ("350", "THB", 35_000),
    ])
    func parsesWhatPeopleType(text: String, currency: String, expected: Int64) {
        #expect(Money.parse(text, currency) == expected)
    }

    @Test(arguments: ["", "  ", "abc", "-5", "−5", "12a", "1e5", "9999999999999999"])
    func rejectsWhatIsNotAnAmount(text: String) {
        #expect(Money.parse(text, "EUR") == nil)
    }

    @Test func formatsWithTheCurrencysOwnDecimals() {
        #expect(Money.format(1250, "EUR", locale: us) == "€12.50")
        #expect(Money.format(1200, "JPY", locale: us) == "¥1,200")
        #expect(Money.format(-1500, "USD", locale: us) == "-$15.00")
        #expect(Money.format(1250, "KWD", locale: us).contains("1.250"))
        #expect(Money.formatSigned(1500, "USD", locale: us) == "+$15.00")
        #expect(Money.formatSigned(0, "USD", locale: us) == "$0.00")
        #expect(Money.formatSigned(-1500, "USD", locale: us) == "-$15.00")
    }

    @Test func editableTextRoundTrips() {
        for (minor, currency) in [(Int64(1250), "EUR"), (123_456, "USD"), (1200, "JPY"), (1250, "KWD")] {
            let text = Money.editableText(minor, currency, locale: us)
            #expect(Money.parse(text, currency) == minor, "\(text)")
        }
        #expect(Money.editableText(123_456, "EUR", locale: Locale(identifier: "de_DE")) == "1234,56")
    }

    @Test func roundsHalvesAwayFromZero() throws {
        #expect(Money.rounded(try #require(Decimal(string: "2.5"))) == 3)
        #expect(Money.rounded(try #require(Decimal(string: "-2.5"))) == -3)
        #expect(Money.rounded(try #require(Decimal(string: "2.4999"))) == 2)
    }

    @Test func convertsAtARateIntoTheTargetsMinorUnit() throws {
        // 10.00 THB at 0.0256 = 0.256 EUR → 0.26
        #expect(Money.convert(1000, from: "THB", to: "EUR", rate: try #require(Decimal(string: "0.0256"))) == 26)
        // ¥1,000 at 0.0067 = $6.70
        #expect(Money.convert(1000, from: "JPY", to: "USD", rate: try #require(Decimal(string: "0.0067"))) == 670)
        // €12.50 at 160.5 = ¥2,006.25 → ¥2,006
        #expect(Money.convert(1250, from: "EUR", to: "JPY", rate: try #require(Decimal(string: "160.5"))) == 2006)
        // Same currency: untouched whatever the rate.
        #expect(Money.convert(1250, from: "EUR", to: "eur", rate: 2) == 1250)
    }

    @Test func ratesParseAndKeepEveryDigit() throws {
        #expect(Money.parseRate("36,5") == Decimal(string: "36.5"))
        #expect(Money.parseRate(" 0.0274 ") == Decimal(string: "0.0274"))
        #expect(Money.parseRate("0") == nil)
        #expect(Money.parseRate("abc") == nil)
        #expect(Money.parseRate("1.2.3") == nil)
        #expect(Money.parseRate("") == nil)

        let rate = try #require(Decimal(string: "36.512345678901"))
        #expect(Money.rateText(rate) == "36.512345678901")
        #expect(Money.rate(fromText: Money.rateText(rate)) == rate)
    }
}
