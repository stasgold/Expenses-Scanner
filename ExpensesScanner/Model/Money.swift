import Foundation

/// ISO 4217 currency code, e.g. "EUR".
typealias CurrencyCode = String

/**
 * Money is always a whole number of the currency's minor unit (cents, pence, yen) plus a currency code.
 * Floating point never touches an amount, so sums, splits and conversions are exact and reproducible.
 * Exchange rates are `Decimal`.
 */
enum Money {
    /// Currencies whose minor unit isn't a hundredth (ISO 4217). Every other currency has two decimals.
    private static let minorDigitExceptions: [String: Int] = [
        "BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0, "PYG": 0,
        "RWF": 0, "UGX": 0, "UYI": 0, "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
        "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
        "CLF": 4, "UYW": 4,
    ]

    /// Amounts above this (in minor units) are refused when typed: far beyond any trip, far below overflow.
    static let maximumMinor: Int64 = 999_999_999_999_999

    /// Decimals the currency uses: 2 for EUR, 0 for JPY, 3 for KWD.
    static func minorDigits(_ currency: CurrencyCode) -> Int {
        minorDigitExceptions[currency.uppercased()] ?? 2
    }

    /// Minor units in one major unit: 100 for EUR, 1 for JPY, 1000 for KWD.
    static func scale(_ currency: CurrencyCode) -> Int64 {
        (0..<minorDigits(currency)).reduce(Int64(1)) { result, _ in result * 10 }
    }

    /// 1250 EUR cents → 12.5
    static func decimal(_ minor: Int64, _ currency: CurrencyCode) -> Decimal {
        Decimal(minor) / Decimal(scale(currency))
    }

    /// 12.505 EUR → 1251 cents (nearest, halves away from zero).
    static func minor(_ value: Decimal, _ currency: CurrencyCode) -> Int64 {
        rounded(value * Decimal(scale(currency)))
    }

    /// Nearest whole number, halves away from zero.
    static func rounded(_ value: Decimal) -> Int64 {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, .plain)
        return NSDecimalNumber(decimal: result).int64Value
    }

    /// Converts between currencies at `rate` (one unit of `from` in `to`), rounding to `to`'s minor unit.
    static func convert(_ minor: Int64, from: CurrencyCode, to: CurrencyCode, rate: Decimal) -> Int64 {
        guard from.uppercased() != to.uppercased() else { return minor }
        return self.minor(decimal(minor, from) * rate, to)
    }

    // MARK: Formatting

    /// "€12.50", "¥1,200", "KWD 1.250" in the given locale, always with the currency's own decimals.
    static func format(_ minor: Int64, _ currency: CurrencyCode, locale: Locale = .current) -> String {
        decimal(minor, currency).formatted(
            .currency(code: currency)
                .precision(.fractionLength(minorDigits(currency)))
                .locale(locale)
        )
    }

    /// Like `format`, with a leading "+" on positive amounts: balances read as owed or owing.
    static func formatSigned(_ minor: Int64, _ currency: CurrencyCode, locale: Locale = .current) -> String {
        minor > 0 ? "+" + format(minor, currency, locale: locale) : format(minor, currency, locale: locale)
    }

    /// The amount as the user would type it back: "12.50" or "12,50" by locale, no grouping, no symbol.
    static func editableText(_ minor: Int64, _ currency: CurrencyCode, locale: Locale = .current) -> String {
        decimal(minor, currency).formatted(
            .number
                .precision(.fractionLength(minorDigits(currency)))
                .grouping(.never)
                .locale(locale)
        )
    }

    // MARK: Parsing

    /**
     * Reads an amount the user typed: "12", "12.5", "12,50", "1 234,56", "1,234.56", "€ 8".
     * With both "." and "," present the last one is the decimal separator. With only one kind, a single
     * separator is decimal unless exactly three digits follow it ("1,234" and "1.500" are thousands), except
     * after a leading 0 ("0,500") or in a three-decimal currency ("1.250" KWD). Extra decimals are rounded.
     * Returns nil for negative, empty or non-numeric text.
     */
    static func parse(_ text: String, _ currency: CurrencyCode) -> Int64? {
        var kept: [Character] = []
        for character in text {
            if character.isASCII && (character.isNumber || character == "." || character == ",") {
                kept.append(character)
            } else if character.isWhitespace || character == "'" || character == "’" || character.isCurrencySymbol {
                continue
            } else {
                return nil
            }
        }
        let string = String(kept)
        guard string.contains(where: \.isNumber) else { return nil }

        let lastDot = string.lastIndex(of: ".")
        let lastComma = string.lastIndex(of: ",")
        var decimalIndex: String.Index?
        if let lastDot, let lastComma {
            decimalIndex = max(lastDot, lastComma)
        } else if let separator = lastDot ?? lastComma {
            let occurrences = string.filter { $0 == string[separator] }.count
            let digitsAfter = string.distance(from: string.index(after: separator), to: string.endIndex)
            let integerPart = string[..<separator]
            if occurrences == 1 && (digitsAfter != 3 || minorDigits(currency) == 3 || integerPart.isEmpty || integerPart == "0") {
                decimalIndex = separator
            }
        }

        let integerDigits: String
        let fractionDigits: String
        if let decimalIndex {
            integerDigits = string[..<decimalIndex].filter(\.isNumber)
            fractionDigits = string[string.index(after: decimalIndex)...].filter(\.isNumber)
        } else {
            integerDigits = string.filter(\.isNumber)
            fractionDigits = ""
        }
        let trimmedInteger = integerDigits.drop(while: { $0 == "0" })
        guard trimmedInteger.count <= 15 else { return nil }

        let posix = "\(integerDigits.isEmpty ? "0" : integerDigits).\(fractionDigits.isEmpty ? "0" : fractionDigits)"
        guard let value = Decimal(string: posix, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let result = minor(value, currency)
        return result <= maximumMinor ? result : nil
    }

    /// Reads an exchange rate typed by the user: "36.5", "36,5", "0.0274". Nil unless positive.
    static func parseRate(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              cleaned.filter({ $0 == "." }).count <= 1,
              let rate = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              rate > 0
        else { return nil }
        return rate
    }

    /// Rates are stored as text so no digit is ever lost: "36.512".
    static func rateText(_ rate: Decimal) -> String {
        NSDecimalNumber(decimal: rate).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    static func rate(fromText text: String?) -> Decimal? {
        guard let text else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: Currencies

    /// The device region's currency, or USD.
    static var localCurrency: CurrencyCode {
        Locale.current.currency?.identifier ?? "USD"
    }

    /// Every currency worth offering, by code.
    static var allCurrencies: [CurrencyCode] {
        Locale.commonISOCurrencyCodes.sorted()
    }

    /// "Euro", "Thai Baht" in the user's language; the code itself when unknown.
    static func name(_ currency: CurrencyCode, locale: Locale = .current) -> String {
        locale.localizedString(forCurrencyCode: currency) ?? currency
    }
}
