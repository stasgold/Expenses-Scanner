import Foundation

/// One line of a receipt as the editor holds it.
struct ReceiptItemDraft: Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Line total in minor units of the receipt's currency.
    var amount: Int64
    var quantity: Int = 1
    /// Where it is on the photo.
    var box: OCRBox?
    /// Who had it: 1 is a normal share, 2 counts double; missing or 0 means not them.
    var weights: [UUID: Int]
    /// The name in the reader's language, and which one (BCP 47).
    var translatedName: String?
    var translatedLanguage: String?
}

/// A scanned (or scanned and edited) receipt before it is saved.
struct ReceiptExpenseDraft: Equatable {
    var title: String = ""
    var date: Date = Date()
    var currency: CurrencyCode
    var payerID: UUID?
    var items: [ReceiptItemDraft] = []
    var tax: Int64 = 0
    var taxIncluded = true
    var tip: Int64 = 0
    var service: Int64 = 0
    var discount: Int64 = 0
    var extrasMode: ExtrasMode = .proportional
    /// The total printed on the receipt, to compare with the lines.
    var printedTotal: Int64?
    /// Typed by the user; nil lets the app fetch one.
    var rateToHome: Decimal?
    /// JPEG of the receipt.
    var photo: Data?
    /// The lines as read, kept for re-reading in another currency and for the translated receipt.
    var rows: [ReceiptRow] = []
    /// The language the receipt is written in (BCP 47), once known.
    var sourceLanguage: String?

    init(currency: CurrencyCode) {
        self.currency = currency
    }

    /**
     * What the scanner read, ready to review. Everyone shares every line until told otherwise, so
     * saving straight away already splits the bill evenly.
     */
    init(parsed: ParsedReceipt, rows: [ReceiptRow], currency: CurrencyCode, date: Date, payer: UUID?, participants: [UUID], photo: Data?) {
        self.currency = parsed.currency ?? currency
        title = parsed.merchant ?? ""
        self.date = parsed.date ?? date
        payerID = payer
        let everyone = Dictionary(uniqueKeysWithValues: participants.map { ($0, 1) })
        items = parsed.items.map {
            ReceiptItemDraft(name: $0.name, amount: $0.amount, quantity: $0.quantity, box: $0.box, weights: everyone)
        }
        tax = parsed.tax
        taxIncluded = parsed.taxIncluded
        tip = parsed.tip
        service = parsed.service
        discount = parsed.discount
        printedTotal = parsed.total
        self.photo = photo
        self.rows = rows
        // Only the total could be read: start from it as one line everyone shares.
        if items.isEmpty, let total = parsed.total, total > 0 {
            useTotalAsOneLine(sharedBy: everyone)
        }
    }

    /**
     * Replaces the lines with one line for the printed total. Tax, tip, service and discounts are
     * already inside that total, so they're cleared rather than added again (tax stays, as included).
     */
    mutating func useTotalAsOneLine(sharedBy weights: [UUID: Int]) {
        guard let total = printedTotal, total > 0 else { return }
        items = [ReceiptItemDraft(name: L10n.wholeReceipt, amount: total, weights: weights)]
        taxIncluded = true
        tip = 0
        service = 0
        discount = 0
    }

    var input: ExpenseInput {
        ExpenseInput(
            lines: items.map { item in
                LineInput(
                    amount: item.amount,
                    shares: item.weights
                        .filter { $0.value > 0 }
                        .sorted { $0.key.uuidString < $1.key.uuidString }
                        .map { ShareInput(participant: $0.key, weight: $0.value) }
                )
            },
            tax: tax,
            taxIncluded: taxIncluded,
            tip: tip,
            service: service,
            discount: discount,
            extrasMode: extrasMode
        )
    }

    /// Printed total minus what the lines and extras add up to; nil without a printed total.
    var mismatch: Int64? {
        printedTotal.map { $0 - input.total }
    }

    /// Saveable with at least one line, or with just the printed total (saved as one line).
    var isValid: Bool {
        payerID != nil && (!items.isEmpty || (printedTotal ?? 0) > 0)
    }
}
