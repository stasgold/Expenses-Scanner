import Foundation

/// Where something sits on the receipt photo, normalised 0…1 with the origin at the top left.
struct OCRBox: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func union(_ other: OCRBox) -> OCRBox {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        return OCRBox(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }
}

/// One piece of text the recogniser found, with its position.
struct OCRFragment: Codable, Equatable {
    var text: String
    var box: OCRBox
}

/// One printed line of the receipt: its fragments left to right.
struct ReceiptRow: Codable, Equatable {
    var fragments: [OCRFragment]

    var text: String { fragments.map(\.text).joined(separator: " ") }
    var box: OCRBox? {
        fragments.map(\.box).reduce(nil) { partial, box in partial?.union(box) ?? box }
    }
}

/**
 * Receipts are two columns (name … price) that the recogniser often returns as separate pieces.
 * Pieces whose vertical centres lie within half a typical line height of each other form one row.
 */
enum LineGrouper {
    static func rows(_ fragments: [OCRFragment]) -> [ReceiptRow] {
        let pieces = fragments
            .filter { !$0.text.trimmed.isEmpty }
            .sorted { $0.box.midY < $1.box.midY }
        guard !pieces.isEmpty else { return [] }
        let heights = pieces.map(\.box.height).sorted()
        let tolerance = max(heights[heights.count / 2] * 0.5, 0.002)

        var rows: [[OCRFragment]] = []
        var centres: [Double] = []
        for piece in pieces {
            if let last = rows.indices.last, abs(centres[last] - piece.box.midY) <= tolerance {
                rows[last].append(piece)
                centres[last] = rows[last].map(\.box.midY).reduce(0, +) / Double(rows[last].count)
            } else {
                rows.append([piece])
                centres.append(piece.box.midY)
            }
        }
        return rows.map { ReceiptRow(fragments: $0.sorted { $0.box.x < $1.box.x }) }
    }
}

struct ParsedItem: Equatable {
    var name: String
    /// Line total in minor units.
    var amount: Int64
    var quantity: Int
    var box: OCRBox?
}

/// What the parser read off a receipt. Everything is editable afterwards; nothing here is trusted blindly.
struct ParsedReceipt: Equatable {
    /// The first line that looks like a name: usually the shop or restaurant.
    var merchant: String?
    var date: Date?
    /// The currency printed on the receipt; nil when it doesn't say (or only says "$").
    var currency: CurrencyCode?
    var items: [ParsedItem] = []
    var subtotal: Int64?
    var tax: Int64 = 0
    /// VAT-style tax already inside the prices (shown, not added).
    var taxIncluded = true
    var tip: Int64 = 0
    var service: Int64 = 0
    var discount: Int64 = 0
    /// The total printed on the receipt.
    var total: Int64?

    var itemsTotal: Int64 { items.reduce(0) { $0 + $1.amount } }
    var computedTotal: Int64 { itemsTotal + (taxIncluded ? 0 : tax) + tip + service - discount }
    /// Printed total minus what the lines add up to; nil without a printed total.
    var mismatch: Int64? { total.map { $0 - computedTotal } }
}

/**
 * Turns receipt rows into items, extras and a total. Pure: no Vision, so every rule is unit-tested.
 *
 *  1. The currency comes from codes and symbols on the receipt (falling back to `currency`).
 *  2. The decimal separator is decided once per receipt, by which one most prices end with.
 *  3. A row's price is its right-most amount. Its words decide what it is: an item, or a subtotal,
 *     total, tax, tip, service charge, discount or payment line, in about 20 languages.
 *  4. After the total (or the first payment line) only tax breakdowns are read.
 *  5. Whether tax is added on top or already included is decided by which sum matches the total.
 */
enum ReceiptParser {
    /// `detectCurrency: false` reads the receipt in `currency` whatever it prints (the user picked it).
    static func parse(_ rows: [ReceiptRow], currency hint: CurrencyCode, detectCurrency shouldDetect: Bool = true, now: Date = Date()) -> ParsedReceipt {
        let detected = shouldDetect ? detectCurrency(rows) : nil
        let currency = detected ?? hint
        let tokensByRow = rows.map { moneyTokens(in: $0.text) }
        let style = NumberStyle.detect(tokensByRow.flatMap { $0 }, currencyDigits: Money.minorDigits(currency))
        let scale = Money.scale(currency)

        var result = ParsedReceipt()
        result.currency = detected
        result.date = detectDate(rows, now: now)

        var pending: (index: Int, name: String, box: OCRBox?, category: LineCategory?)?
        var afterTotal = false
        var taxAfterTotal: Int64 = 0
        var includedHint = false

        for (index, row) in rows.enumerated() {
            let tokens = tokensByRow[index]
            let rowPrice = tokens.last.flatMap { style.value($0, scale: scale) }
            let label = normalized(row.text)
            var category = classify(label)
            if category == .tax && containsAny(label, includedMarkers) { includedHint = true }
            let adjacent = pending.flatMap { $0.index == index - 1 ? $0 : nil }
            defer { if rowPrice != nil { pending = nil } }

            if afterTotal {
                if category == .tax, let rowPrice { taxAfterTotal += abs(rowPrice) }
                continue
            }
            guard let price = rowPrice else {
                let name = cleanName(row.text)
                if result.merchant == nil, result.items.isEmpty, category == nil, letterCount(name) >= 3 {
                    result.merchant = name
                }
                pending = (index, name, row.box, category)
                continue
            }
            // "TOTAL" on one line and the amount on the next.
            if category == nil, letterCount(cleanName(row.text)) < 2, let adjacent, adjacent.category != nil {
                category = adjacent.category
            }

            switch category {
            case .subtotal?:
                result.subtotal = abs(price)
            case .total?:
                if result.total == nil { result.total = abs(price) }
                afterTotal = true
            case .tax?:
                result.tax += abs(price)
            case .tip?:
                result.tip += abs(price)
            case .service?:
                result.service += abs(price)
            case .discount?:
                result.discount += abs(price)
            case .payment?:
                afterTotal = true
            case nil:
                // "2 x 1,49" under the item it belongs to.
                if let quantity = quantityOnly(row.text), adjacent == nil, !result.items.isEmpty {
                    result.items[result.items.count - 1].quantity = quantity
                    continue
                }
                if price < 0 {
                    result.discount += -price
                    continue
                }
                var name = cleanName(row.text)
                var box = row.box
                // Name on one line, quantity and price on the next.
                if letterCount(name) < 2, let adjacent, adjacent.category == nil, letterCount(adjacent.name) >= 2 {
                    name = adjacent.name
                    box = [adjacent.box, row.box].compactMap { $0 }.reduce(OCRBox?.none) { $0?.union($1) ?? $1 }
                    if result.merchant == adjacent.name && result.items.isEmpty { result.merchant = nil }
                }
                result.items.append(ParsedItem(name: name, amount: price, quantity: quantity(in: row.text), box: box))
            }
        }

        resolveTax(&result, taxAfterTotal: taxAfterTotal, includedHint: includedHint)
        return result
    }

    /// Tax added on top (US, Thai service + VAT) or already in the prices (EU, Japan): whichever sum
    /// matches the printed total wins; markers like "incl." decide when nothing matches.
    private static func resolveTax(_ result: inout ParsedReceipt, taxAfterTotal: Int64, includedHint: Bool) {
        if result.tax == 0 {
            result.tax = taxAfterTotal
            result.taxIncluded = true
            return
        }
        let extras = result.tip + result.service - result.discount
        let base = result.itemsTotal + extras
        func near(_ value: Int64) -> Bool {
            guard let total = result.total else { return false }
            return abs(value - total) <= 2
        }
        if near(base) {
            result.taxIncluded = true
        } else if near(base + result.tax) {
            result.taxIncluded = false
        } else if let subtotal = result.subtotal, near(subtotal + result.tax + extras) {
            result.taxIncluded = false
        } else if let subtotal = result.subtotal, near(subtotal + extras) {
            result.taxIncluded = true
        } else {
            result.taxIncluded = includedHint || taxAfterTotal > 0
        }
    }

    // MARK: Line kinds

    enum LineCategory: CaseIterable {
        case subtotal, total, tax, tip, service, discount, payment
    }

    private static let keywords: [LineCategory: [String]] = [
        .subtotal: [
            "subtotal", "sub total", "sub-total", "zwischensumme", "sous-total", "sous total", "subtotale",
            "subtotaal", "промежуточный итог", "подытог", "小計", "小计", "税込小計", "소계", "ยอดรวมย่อย",
            "tạm tính", "ara toplam", "suma częściowa", "mezisoučet", "välisumma",
        ],
        .total: [
            "total", "grand total", "totale", "gesamt", "gesamtbetrag", "summe", "importe", "montant", "totaal",
            "итого", "всего", "к оплате", "合計", "合计", "总计", "總計", "税込合計", "お会計", "합계", "총액",
            "รวมทั้งสิ้น", "ยอดรวม", "ยอดสุทธิ", "tổng", "toplam", "razem", "suma", "celkem", "yhteensä",
            "amount due", "balance due", "to pay", "a pagar", "à payer", "zu zahlen", "da pagare", "te betalen",
        ],
        .tax: [
            "tax", "sales tax", "vat", "mwst", "ust", "tva", "iva", "btw", "gst", "hst", "pst", "qst", "moms",
            "ндс", "消費税", "税", "增值税", "부가세", "부가가치세", "ภาษี", "thuế", "kdv", "ptu", "dph", "alv",
            "impuesto", "imposto", "impôt",
        ],
        .tip: [
            "tip", "gratuity", "trinkgeld", "pourboire", "propina", "mancia", "fooi", "gorjeta", "чаевые",
            "チップ", "小费", "팁", "ทิป", "bahşiş", "napiwek",
        ],
        .service: [
            "service", "service charge", "servizio", "coperto", "cover charge", "serviço", "servicio",
            "bedienung", "サービス料", "服务费", "봉사료", "ค่าบริการ", "phí dịch vụ", "servis",
        ],
        .discount: [
            "discount", "rabatt", "remise", "réduction", "descuento", "sconto", "korting", "desconto", "скидка",
            "割引", "値引", "折扣", "优惠", "할인", "ส่วนลด", "giảm giá", "indirim", "rabat", "sleva", "coupon",
            "promo", "voucher", "off",
        ],
        .payment: [
            "cash", "card", "visa", "mastercard", "master card", "amex", "american express", "maestro",
            "change", "rückgeld", "wechselgeld", "bar gegeben", "barzahlung", "kartenzahlung", "girocard",
            "ec-karte", "monnaie", "rendu", "espèces", "carte bancaire", "carte bleue", "cb", "efectivo",
            "cambio", "tarjeta", "contanti", "resto", "bancomat", "contant", "wisselgeld", "наличные", "сдача",
            "お釣り", "お預り", "お預かり", "現金", "クレジット", "现金", "找零", "거스름돈", "현금", "카드",
            "เงินสด", "เงินทอน", "tiền mặt", "tiền thừa", "nakit", "para üstü", "gotówka", "reszta",
            "tendered", "paid", "payment", "auth", "approval", "contactless", "debit", "credit",
        ],
    ]

    /// Words saying the tax is already inside the prices.
    private static let includedMarkers = [
        "incl", "inkl", "enthalten", "included", "inclus", "incluido", "incluida", "incluso", "inclusa",
        "inbegrepen", "内", "込", "포함", "รวมภาษี", "bao gồm", "dahil",
    ]

    /// The kind of line whose keyword appears first (a longer keyword wins a tie): "Subtotal" is a
    /// subtotal, "MwSt gesamt" a tax line, "Total incl. VAT" a total.
    static func classify(_ label: String) -> LineCategory? {
        var best: (category: LineCategory, start: Int, length: Int)?
        for category in LineCategory.allCases {
            for keyword in keywords[category] ?? [] {
                guard let start = position(of: normalized(keyword), in: label) else { continue }
                let length = keyword.count
                if best == nil || start < best!.start || (start == best!.start && length > best!.length) {
                    best = (category, start, length)
                }
            }
        }
        return best?.category
    }

    private static func containsAny(_ label: String, _ words: [String]) -> Bool {
        words.contains { position(of: normalized($0), in: label) != nil }
    }

    /// Where `keyword` starts in `label`. Latin keywords match whole words only ("tip" is not in
    /// "tipsy"); other scripts match anywhere.
    private static func position(of keyword: String, in label: String) -> Int? {
        if let regex = wordPatterns[keyword] {
            guard let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let range = Range(match.range, in: label)
            else { return nil }
            return label.distance(from: label.startIndex, to: range.lowerBound)
        }
        guard let range = label.range(of: keyword) else { return nil }
        return label.distance(from: label.startIndex, to: range.lowerBound)
    }

    /// Whole-word patterns for every Latin keyword, compiled once.
    private static let wordPatterns: [String: NSRegularExpression] = {
        var patterns: [String: NSRegularExpression] = [:]
        for word in keywords.values.flatMap({ $0 }) + includedMarkers {
            let keyword = normalized(word)
            guard keyword.unicodeScalars.allSatisfy({ $0.isASCII }), patterns[keyword] == nil else { continue }
            let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: keyword) + "(?![a-z])"
            patterns[keyword] = try? NSRegularExpression(pattern: pattern)
        }
        return patterns
    }()

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    // MARK: Amounts

    /// A token that looks like an amount: its digits and separators, and whether it was negative.
    struct MoneyToken: Equatable {
        var core: String
        var negative: Bool
    }

    /// Every amount-like token in a line, left to right: "12,50", "€8.00", "-2.00", "3.50-", "(1.20)",
    /// "12.50EUR". Percentages, times, dates and codes with letters inside are not amounts.
    static func moneyTokens(in text: String) -> [MoneyToken] {
        text.split(whereSeparator: \.isWhitespace).compactMap { moneyToken(String($0)) }
    }

    static func moneyToken(_ token: String) -> MoneyToken? {
        guard !token.contains("%"),
              let first = token.firstIndex(where: { $0.isASCII && $0.isNumber }),
              let last = token.lastIndex(where: { $0.isASCII && $0.isNumber })
        else { return nil }
        let core = String(token[first...last])
        guard core.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," || $0 == "'" }) else { return nil }
        let prefix = token[..<first]
        let suffix = token[token.index(after: last)...]
        // Only symbols, signs and currency letters may surround the number: "x2" or "A12" are not amounts…
        // but "12.50A" (a VAT class) and "EUR12.50" are.
        guard prefix.count <= 4, suffix.count <= 4 else { return nil }
        guard !prefix.contains(where: { $0.isLetter }) || prefix.filter(\.isLetter).count >= 2 else { return nil }
        let negative = prefix.contains("-") || prefix.contains("−") || suffix.contains("-") || suffix.contains("−")
            || (prefix.contains("(") && suffix.contains(")"))
        return MoneyToken(core: core, negative: negative)
    }

    /// How a receipt writes its amounts.
    struct NumberStyle: Equatable {
        /// "." or ",".
        var decimalSeparator: Character
        /// Decimals printed on prices: the currency's, or 0 when prices are printed in whole units
        /// (yen, or "25.000" rupiah).
        var decimals: Int

        static func detect(_ tokens: [MoneyToken], currencyDigits: Int) -> NumberStyle {
            guard currencyDigits > 0 else { return NumberStyle(decimalSeparator: ".", decimals: 0) }
            var dots = 0
            var commas = 0
            for token in tokens {
                guard let separator = token.core.lastIndex(where: { $0 == "." || $0 == "," }) else { continue }
                let after = token.core.distance(from: token.core.index(after: separator), to: token.core.endIndex)
                guard after == currencyDigits else { continue }
                if token.core[separator] == "." { dots += 1 } else { commas += 1 }
            }
            if dots + commas == 0 {
                return NumberStyle(decimalSeparator: ".", decimals: 0)
            }
            return NumberStyle(decimalSeparator: commas > dots ? "," : ".", decimals: currencyDigits)
        }

        /// The token in minor units, or nil when it isn't an amount in this style ("12" when prices
        /// have cents, "12.10.26", "1.2345").
        func value(_ token: MoneyToken, scale: Int64) -> Int64? {
            let core = token.core
            var integerPart = Substring(core)
            var fraction = Substring("")
            if decimals > 0 {
                guard let separator = core.lastIndex(where: { $0 == "." || $0 == "," || $0 == "'" }),
                      core[separator] == decimalSeparator
                else { return nil }
                integerPart = core[..<separator]
                fraction = core[core.index(after: separator)...]
                guard fraction.count == decimals, fraction.allSatisfy(\.isNumber) else { return nil }
            }
            guard let whole = Self.groupedInteger(integerPart) else { return nil }
            let fractionValue = Int64(fraction) ?? 0
            let minor: Int64
            if decimals > 0 {
                // Printed decimals equal the currency's, so the digits are minor units already.
                minor = whole * scale + fractionValue
            } else {
                minor = whole * scale
            }
            return token.negative ? -minor : minor
        }

        /// "1.234", "1,234", "1'234", "1234" → 1234; nil for bad grouping like "12.10".
        static func groupedInteger(_ text: Substring) -> Int64? {
            if text.isEmpty { return 0 }
            let groups = text.split(separator: ",", omittingEmptySubsequences: false)
                .flatMap { $0.split(separator: ".", omittingEmptySubsequences: false) }
                .flatMap { $0.split(separator: "'", omittingEmptySubsequences: false) }
            guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
            if groups.count > 1 {
                guard (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            }
            let digits = groups.joined()
            guard digits.count <= 13 else { return nil }
            return Int64(digits)
        }
    }

    // MARK: Names and quantities

    private static let currencyCodes = Set(Locale.commonISOCurrencyCodes)

    private static let unitWords: Set<String> = ["kg", "g", "gr", "lb", "lbs", "l", "ml", "cl", "pcs", "pc", "st", "stk", "ea"]

    /// The words of a line without its amounts, quantities, unit prices, codes and VAT classes.
    static func cleanName(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var kept: [String] = []
        for token in tokens {
            let lower = token.lowercased()
            if moneyToken(token) != nil { continue }
            if token.contains("%") || token.contains("/") { continue }
            if ["x", "×", "*", "@", "-", "–", "—", "=", ":"].contains(lower) { continue }
            if lower.range(of: #"^\d{1,3}[x×*@]$"#, options: .regularExpression) != nil { continue }
            if unitWords.contains(lower.trimmingCharacters(in: .punctuationCharacters)) { continue }
            if token.count == 3, token == token.uppercased(), token.allSatisfy(\.isLetter), currencyCodes.contains(token) { continue }
            if token.allSatisfy({ $0.isCurrencySymbol }) { continue }
            kept.append(token)
        }
        // A trailing single letter is a VAT class ("A", "B"); a leading 4+ digit number an article code.
        if let last = kept.last, last.count == 1, last.first?.isUppercase == true { kept.removeLast() }
        if let first = kept.first, first.count >= 4, first.allSatisfy(\.isNumber) { kept.removeFirst() }
        let joined = kept.joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " .:*-–—_#=•·").union(.whitespaces))
    }

    /// "2 x Beer", "Beer 2 x 3.50", "2x", "2 Beer" → 2; otherwise 1.
    static func quantity(in text: String) -> Int {
        for pattern in [#"^\s*(\d{1,3})\s*[x×*]\s"#, #"(\d{1,3})\s*[x×@]\s*\d"#, #"^\s*(\d{1,2})\s+\p{L}"#] {
            if let value = firstCapture(pattern, in: text).flatMap(Int.init), (1...999).contains(value) {
                return value
            }
        }
        return 1
    }

    /// A line that only says "2 x 1,49": the quantity of the item above.
    static func quantityOnly(_ text: String) -> Int? {
        firstCapture(#"^\s*(\d{1,3})\s*[x×*@]\s*\S+\s*$"#, in: text).flatMap(Int.init)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func letterCount(_ text: String) -> Int {
        text.filter(\.isLetter).count
    }

    // MARK: Currency and date

    private static let symbolCurrencies: [(symbol: String, currency: CurrencyCode)] = [
        ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"), ("￥", "JPY"), ("₩", "KRW"), ("฿", "THB"), ("₫", "VND"),
        ("₹", "INR"), ("₺", "TRY"), ("₴", "UAH"), ("₽", "RUB"), ("₪", "ILS"), ("₱", "PHP"), ("R$", "BRL"),
    ]

    /// Written currencies that only count right next to a number ("1,200円", "350 บาท", "12,50 zł").
    private static let wordCurrencies: [(word: String, currency: CurrencyCode)] = [
        ("円", "JPY"), ("元", "CNY"), ("원", "KRW"), ("บาท", "THB"), ("zł", "PLN"), ("Kč", "CZK"), ("Ft", "HUF"),
        ("RMB", "CNY"), ("лв", "BGN"),
    ]

    /// The currency the receipt is written in: the most frequent code or symbol. "$" alone says nothing
    /// (it is used by dozens of currencies), so it never decides.
    static func detectCurrency(_ rows: [ReceiptRow]) -> CurrencyCode? {
        let known = Set(Locale.commonISOCurrencyCodes)
        var votes: [CurrencyCode: Int] = [:]
        for row in rows {
            let text = row.text
            let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
            for (index, token) in tokens.enumerated() {
                // "EUR 12.50", "12.50 EUR", "EUR12.50", "12.50EUR"
                let letters = token.filter { $0.isLetter }
                if letters.count == 3, letters == letters.uppercased(), known.contains(letters) {
                    let attached = moneyToken(token) != nil
                    let neighbour = [index - 1, index + 1].contains { tokens.indices.contains($0) && moneyToken(tokens[$0]) != nil }
                    if attached || neighbour { votes[letters, default: 0] += 1 }
                }
            }
            for (symbol, currency) in symbolCurrencies where text.contains(symbol) {
                votes[currency, default: 0] += text.components(separatedBy: symbol).count - 1
            }
            for (word, currency) in wordCurrencies {
                let escaped = NSRegularExpression.escapedPattern(for: word)
                let pattern = #"(\d\s?"# + escaped + #"(?!\p{L}))|((?<!\p{L})"# + escaped + #"\s?\d)"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let count = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                    if count > 0 { votes[currency, default: 0] += count }
                }
            }
        }
        // "¥" is also the yuan: when the receipt says 元 or RMB, it is.
        if let yen = votes["JPY"], votes["CNY"] != nil {
            votes["CNY", default: 0] += yen
            votes["JPY"] = nil
        }
        return votes.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// The first date printed on the receipt. Times on their own ("12:30") are ignored, and so are
    /// dates more than two years back or in the future.
    static func detectDate(_ rows: [ReceiptRow], now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        for row in rows {
            let text = row.text
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let date = match.date, let range = Range(match.range, in: text) else { continue }
                let found = text[range]
                guard found.contains(where: { "./-年".contains($0) }) || found.contains(where: \.isLetter) else { continue }
                guard date <= now.addingTimeInterval(2 * 86_400), date >= now.addingTimeInterval(-730 * 86_400) else { continue }
                return date
            }
        }
        return nil
    }
}
