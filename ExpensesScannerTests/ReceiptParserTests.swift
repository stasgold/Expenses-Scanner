import Foundation
import Testing
@testable import ExpensesScanner

/// Receipt rows from text: one line per row, two or more spaces between the pieces the recogniser
/// would return separately (name … price).
func receiptRows(_ text: String) -> [ReceiptRow] {
    text.split(separator: "\n").enumerated().map { index, line in
        let pieces = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ReceiptRow(fragments: pieces.enumerated().map { column, piece in
            OCRFragment(text: piece, box: OCRBox(x: 0.05 + Double(column) * 0.3, y: 0.02 + Double(index) * 0.04, width: 0.25, height: 0.025))
        })
    }
}

struct ReceiptParserTests {
    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
    }()

    private func parse(_ text: String, currency: CurrencyCode = "USD") -> ParsedReceipt {
        ReceiptParser.parse(receiptRows(text), currency: currency, now: now)
    }

    private func items(_ receipt: ParsedReceipt) -> [String] {
        receipt.items.map { "\($0.name)=\($0.amount)" + ($0.quantity > 1 ? "×\($0.quantity)" : "") }
    }

    @Test func americanRestaurantAddsTaxAndTip() {
        let receipt = parse("""
        THE CORNER BISTRO
        123 Main St, Springfield
        Date: 10/08/2026  7:42 PM
        2  Burger  25.00
        Caesar Salad  12.50
        Iced Tea  3.50
        Subtotal  41.00
        Tax  3.59
        Tip  8.00
        Total  52.59
        VISA ****1234  52.59
        """)
        #expect(receipt.merchant == "THE CORNER BISTRO")
        #expect(items(receipt) == ["Burger=2500×2", "Caesar Salad=1250", "Iced Tea=350"])
        #expect(receipt.subtotal == 4100)
        #expect(receipt.tax == 359)
        #expect(receipt.taxIncluded == false)
        #expect(receipt.tip == 800)
        #expect(receipt.total == 5259)
        #expect(receipt.mismatch == 0)
        #expect(receipt.currency == nil)
        #expect(receipt.date != nil)
    }

    @Test func germanSupermarketWithCommaDecimalsAndIncludedVAT() {
        let receipt = parse("""
        REWE Markt GmbH
        Bio Vollmilch  1,19 A
        Bananen
        0,845 kg x 1,99 EUR/kg  1,68 A
        Coca Cola 1,5L  2,98 A
        2 x 1,49
        Pfand  0,50 A
        Rabatt  -0,30 A
        SUMME EUR  6,05
        Bar  10,00
        Rückgeld  3,95
        davon MwSt 19%  0,97
        """, currency: "USD")
        #expect(receipt.currency == "EUR")
        #expect(receipt.merchant == "REWE Markt GmbH")
        #expect(items(receipt) == ["Bio Vollmilch=119", "Bananen=168", "Coca Cola=298×2", "Pfand=50"])
        #expect(receipt.discount == 30)
        #expect(receipt.total == 605)
        #expect(receipt.tax == 97)
        #expect(receipt.taxIncluded)
        #expect(receipt.mismatch == 0)
    }

    @Test func japaneseConvenienceStoreInYen() {
        let receipt = parse("""
        ローソン 渋谷店
        おにぎり 鮭  ¥150
        緑茶  ¥140
        サンドイッチ  ¥380
        小計  ¥670
        (内消費税等 8%  ¥49)
        合計  ¥670
        お預り  ¥1,000
        お釣り  ¥330
        """, currency: "EUR")
        #expect(receipt.currency == "JPY")
        #expect(items(receipt) == ["おにぎり 鮭=150", "緑茶=140", "サンドイッチ=380"])
        #expect(receipt.subtotal == 670)
        #expect(receipt.tax == 49)
        #expect(receipt.taxIncluded)
        #expect(receipt.total == 670)
        #expect(receipt.mismatch == 0)
    }

    @Test func thaiRestaurantAddsServiceAndVAT() {
        let receipt = parse("""
        Baan Thai Restaurant
        Pad Thai  180.00
        Tom Yum Goong  250.00
        2 x Singha  240.00
        Sub Total  670.00
        Service Charge 10%  67.00
        VAT 7%  51.59
        Total  788.59
        Cash  1,000.00
        Change  211.41
        """, currency: "THB")
        #expect(items(receipt) == ["Pad Thai=18000", "Tom Yum Goong=25000", "Singha=24000×2"])
        #expect(receipt.subtotal == 67000)
        #expect(receipt.service == 6700)
        #expect(receipt.tax == 5159)
        #expect(receipt.taxIncluded == false)
        #expect(receipt.total == 78859)
        #expect(receipt.mismatch == 0)
    }

    @Test func italianTrattoriaWithCoverChargeAndThousands() {
        let receipt = parse("""
        Trattoria da Mario
        Coperto  2  6,00
        Bistecca fiorentina  1.234,50
        Vino della casa  18,00
        Totale  1.258,50
        """, currency: "EUR")
        #expect(items(receipt) == ["Bistecca fiorentina=123450", "Vino della casa=1800"])
        #expect(receipt.service == 600)
        #expect(receipt.total == 125_850)
        #expect(receipt.mismatch == 0)
    }

    @Test func totalOnItsOwnLineAndAnUnlabelledDiscount() {
        let receipt = parse("""
        Pub
        Beer 2 x 3.50  7.00
        Nachos  9.00
        Happy hour  -2.00
        TOTAL
        14.00
        """)
        #expect(items(receipt) == ["Beer=700×2", "Nachos=900"])
        #expect(receipt.discount == 200)
        #expect(receipt.total == 1400)
        #expect(receipt.mismatch == 0)
    }

    /// A Japanese train ticket receipt: only the two ¥ amounts are prices. Ticket counts, the day of
    /// the month and other small numbers printed beside the text are not.
    @Test func trainTicketReceiptKeepsOnlyRealPrices() {
        let receipt = parse("""
        取引内容：お買上  ¥8,360
        商場者：。（一種発券業務）  0
        1
        東京都内→京都市内  9
        取引内容：お買上  ¥4,960
        商品名：自由席券  1
        9日東京・品川→京都  10
        """, currency: "EUR")
        #expect(receipt.currency == "JPY")
        #expect(receipt.items.map(\.amount) == [8360, 4960])
        #expect(receipt.items.map(\.name) == ["取引内容：お買上", "取引内容：お買上"])
    }

    /// The cost of skipping bare small numbers: a ¥98 item printed without a sign is missed, and the
    /// total check shows exactly that gap so it can be added by hand.
    @Test func wholeUnitPricesWithoutASignNeedThreeDigits() {
        let receipt = parse("""
        おにぎり  150
        ガム  98
        袋  3
        合計  248
        """, currency: "JPY")
        #expect(items(receipt) == ["おにぎり=150"])
        #expect(receipt.total == 248)
        #expect(receipt.mismatch == 98)
    }

    /// A hotel folio: the amount due is printed first, the items in a dated table below it with the card
    /// payment among them, and room and guest numbers all over. Read from a real receipt photo.
    @Test func hotelFolioWithTheTotalAtTheTop() {
        let receipt = parse("""
        RECEIPT
        MR./MS. Alex Morgan
        AMOUNT DUE  ¥17,500
        (consumption tax  ¥1,590)
        Paid by Credit,CREDIT CARD
        Hotel Sakura Garden
        TEL:03-0000-0000
        Trx#:000000A000000000  2026/10/09 10:53
        Room No.: 214
        MR./MS. : ALEX MORGAN
        PAX  : 1
        PERIOD  : 10/3/2026 - 10/9/2026
        Usage Details
        Mr./Ms.  ALEX MORGAN
        Room  214
        Person  1
        Arrive  10/3/2026
        Departure  10/9/2026
        Date  Description / Charge
        2026/10/03  BREAKFAST  ¥2,500
        2026/10/04  BREAKFAST  ¥2,500
        2026/10/05  BREAKFAST  ¥2,500
        2026/10/06  BREAKFAST  ¥2,500
        2026/10/07  BREAKFAST  ¥2,500
        2026/10/08  CREDIT CARD  -¥17,500
        2026/10/08  BREAKFAST  ¥5,000
        Total  ¥17,500
        (10%Taxable ¥17,500 Includes JCT  ¥1,590)
        * Eligible for the reduced tax rate
        # Nontaxable
        ! Other category
        Example Hospitality Co., Ltd.
        Registrated Number T0000000000000
        Trx#:000000A000000000  2026/10/09 10:53
        """, currency: "EUR")
        #expect(receipt.currency == "JPY")
        #expect(receipt.merchant == "Hotel Sakura Garden")
        #expect(items(receipt) == ["BREAKFAST=2500", "BREAKFAST=2500", "BREAKFAST=2500", "BREAKFAST=2500", "BREAKFAST=2500", "BREAKFAST=5000"])
        #expect(receipt.total == 17_500)
        #expect(receipt.tax == 1590)
        #expect(receipt.taxIncluded)
        #expect(receipt.discount == 0)
        #expect(receipt.mismatch == 0)
    }

    @Test func totalAtTheTopWithItsLinesBelow() {
        let receipt = parse("""
        Invoice
        Amount due  60.00
        Spa  25.00
        Minibar  35.00
        """)
        #expect(items(receipt) == ["Spa=2500", "Minibar=3500"])
        #expect(receipt.total == 6000)
        #expect(receipt.mismatch == 0)
    }

    @Test func aBareNumberIsNotAPriceWhenPricesCarryTheSign() {
        let receipt = parse("""
        Room  312
        Tea  ¥450
        Cake  ¥600
        Total  ¥1,050
        """, currency: "JPY")
        #expect(items(receipt) == ["Tea=450", "Cake=600"])
        #expect(receipt.mismatch == 0)
    }

    @Test func aMissedLineShowsAsAMismatch() {
        let receipt = parse("""
        Coffee  3.50
        Total  7.70
        """)
        #expect(receipt.mismatch == 420)
    }

    @Test func nothingReadable() {
        let receipt = parse("""
        Thank you for your visit!
        www.example.com
        """)
        #expect(receipt.items.isEmpty)
        #expect(receipt.total == nil)
        #expect(receipt.mismatch == nil)
    }

    // MARK: Pieces

    @Test(arguments: [
        ("12.50", "12.50", false, false), ("€8.00", "8.00", false, true), ("-2.00", "2.00", true, false),
        ("3.50-", "3.50", true, false), ("(1.20)", "1.20", true, false), ("12.50EUR", "12.50", false, true),
        ("EUR12.50", "12.50", false, true), ("¥1,200", "1,200", false, true), ("1,200円", "1,200", false, true),
        ("12.50A", "12.50", false, false), ("Rp25.000", "25.000", false, true),
    ])
    func amountTokens(token: String, core: String, negative: Bool, marked: Bool) {
        #expect(ReceiptParser.moneyToken(token) == ReceiptParser.MoneyToken(core: core, negative: negative, marked: marked))
    }

    @Test(arguments: ["19%", "12:30", "A12", "x2", "10/08/2026", "Burger", "4/2", "9日", "330ml", "2枚", "No12"])
    func notAmounts(token: String) {
        #expect(ReceiptParser.moneyToken(token) == nil)
    }

    @Test func numberStyleIsDecidedPerReceipt() {
        let comma = ReceiptParser.NumberStyle.detect(["1,19", "2,98", "1.234,50"].compactMap(ReceiptParser.moneyToken), currencyDigits: 2)
        #expect(comma == ReceiptParser.NumberStyle(decimalSeparator: ",", decimals: 2))
        let dot = ReceiptParser.NumberStyle.detect(["1.19", "2.98", "1,234.50"].compactMap(ReceiptParser.moneyToken), currencyDigits: 2)
        #expect(dot == ReceiptParser.NumberStyle(decimalSeparator: ".", decimals: 2))
        // No cents anywhere: prices are whole units ("25.000" rupiah).
        let whole = ReceiptParser.NumberStyle.detect(["25.000", "120.000"].compactMap(ReceiptParser.moneyToken), currencyDigits: 2)
        #expect(whole.decimals == 0)

        let token = ReceiptParser.MoneyToken(core: "1.234,50", negative: false)
        #expect(comma.value(token, scale: 100) == 123_450)
        #expect(dot.value(token, scale: 100) == nil)
        #expect(comma.value(ReceiptParser.MoneyToken(core: "12.10.26", negative: false), scale: 100) == nil)
        #expect(whole.value(ReceiptParser.MoneyToken(core: "25.000", negative: false), scale: 100) == 2_500_000)
    }

    @Test(arguments: [
        ("Subtotal", ReceiptParser.LineCategory.subtotal), ("SUB TOTAL", .subtotal), ("Grand Total", .total),
        ("Total incl. VAT", .total), ("MwSt gesamt", .tax), ("Service Charge 10%", .service), ("Trinkgeld", .tip),
        ("Rabatt", .discount), ("10% off", .discount), ("VISA ****1234", .payment), ("Rückgeld", .payment),
        ("合計", .total), ("小計", .subtotal), ("税込合計", .total), ("内消費税", .tax), ("합계", .total), ("Tổng cộng", .total),
    ])
    func lineKinds(label: String, category: ReceiptParser.LineCategory) {
        #expect(ReceiptParser.classify(ReceiptParser.normalized(label)) == category)
    }

    @Test(arguments: ["Coffee", "Tipsy cake", "Barbecue platter", "Carte blanche"])
    func itemsAreNotMistakenForKeywords(label: String) {
        #expect(ReceiptParser.classify(ReceiptParser.normalized(label)) == nil)
    }

    @Test func namesLoseAmountsCodesAndVATClasses() {
        #expect(ReceiptParser.cleanName("4011 Bananen 1,68 A") == "Bananen")
        #expect(ReceiptParser.cleanName("2 x Beer 7.00") == "Beer")
        #expect(ReceiptParser.cleanName("Pad Thai ....... 180.00 THB") == "Pad Thai")
        #expect(ReceiptParser.quantity(in: "3 x Espresso 6.00") == 3)
        #expect(ReceiptParser.quantity(in: "Espresso 2 @ 2.00 4.00") == 2)
        #expect(ReceiptParser.quantity(in: "Espresso 2.00") == 1)
        #expect(ReceiptParser.quantityOnly("2 x 1,49") == 2)
        #expect(ReceiptParser.quantityOnly("2 x 1,49  2,98") == nil)
    }

    @Test func currencyFromCodesAndSymbols() {
        #expect(ReceiptParser.detectCurrency(receiptRows("Total  EUR 12.50")) == "EUR")
        #expect(ReceiptParser.detectCurrency(receiptRows("Pho  85.000₫\nTotal  85.000₫")) == "VND")
        #expect(ReceiptParser.detectCurrency(receiptRows("合計  1,200円")) == "JPY")
        #expect(ReceiptParser.detectCurrency(receiptRows("合计  ¥58.00\n人民币  58元")) == "CNY")
        #expect(ReceiptParser.detectCurrency(receiptRows("Total  $12.50")) == nil)
        // A three-letter word that happens to be a code only counts next to an amount.
        #expect(ReceiptParser.detectCurrency(receiptRows("ALL DAY BREAKFAST  9.50")) == nil)
    }

    /// A photo turned slightly: prices on the right sit half a line higher than their names. The text's
    /// own slope straightens it out.
    @Test func tiltedPhotosStillPairNamesWithPrices() {
        let slope = -0.03
        var pieces: [OCRFragment] = []
        for (index, (name, price)) in [("BREAKFAST", "¥2,500"), ("DINNER", "¥4,000"), ("TAXI", "¥1,200")].enumerated() {
            let y = 0.20 + Double(index) * 0.03
            pieces.append(OCRFragment(text: name, box: OCRBox(x: 0.05, y: y, width: 0.4, height: 0.02), slope: slope))
            // Same printed line, but further right, so higher up on a photo tilted this way.
            pieces.append(OCRFragment(text: price, box: OCRBox(x: 0.75, y: y + slope * (0.825 - 0.25), width: 0.15, height: 0.02)))
        }
        #expect(LineGrouper.rows(pieces).map(\.text) == ["BREAKFAST ¥2,500", "DINNER ¥4,000", "TAXI ¥1,200"])
    }

    @Test func rowsAreRebuiltFromPieces() throws {
        let pieces = [
            OCRFragment(text: "4.20", box: OCRBox(x: 0.8, y: 0.150, width: 0.1, height: 0.02)),
            OCRFragment(text: "Coffee", box: OCRBox(x: 0.1, y: 0.100, width: 0.2, height: 0.02)),
            OCRFragment(text: "Cake", box: OCRBox(x: 0.1, y: 0.148, width: 0.2, height: 0.02)),
            OCRFragment(text: "3.50", box: OCRBox(x: 0.8, y: 0.104, width: 0.1, height: 0.02)),
            OCRFragment(text: " ", box: OCRBox(x: 0.5, y: 0.5, width: 0.1, height: 0.02)),
        ]
        let rows = LineGrouper.rows(pieces)
        #expect(rows.map(\.text) == ["Coffee 3.50", "Cake 4.20"])
        let box = try #require(rows.first?.box)
        #expect(abs(box.x - 0.1) < 1e-9 && abs(box.y - 0.1) < 1e-9)
        #expect(abs(box.width - 0.8) < 1e-9 && abs(box.height - 0.024) < 1e-9)
    }
}
