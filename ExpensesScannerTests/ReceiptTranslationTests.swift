import Foundation
import Testing
@testable import ExpensesScanner

/// What gets translated and where the answers go. The translating itself (Apple's Translation
/// framework) needs downloaded languages and isn't available to tests.
struct ReceiptTranslationTests {
    private let ann = UUID()

    private func draft() -> ReceiptExpenseDraft {
        var draft = ReceiptExpenseDraft(currency: "JPY")
        draft.items = [
            ReceiptItemDraft(name: "自由席券", amount: 4960, weights: [ann: 1]),
            ReceiptItemDraft(name: "  ", amount: 100, weights: [ann: 1]),
            ReceiptItemDraft(name: "緑茶", amount: 140, weights: [ann: 1]),
        ]
        draft.rows = receiptRows("""
        JR東海 領収書
        自由席券  ¥4,960
        1234
        """)
        return draft
    }

    @Test func detectsTheReceiptsLanguage() {
        #expect(ReceiptTranslation.detectLanguage(["領収書", "自由席券 ¥4,960", "お買上げありがとうございます"])?.languageCode == "ja")
        #expect(ReceiptTranslation.detectLanguage(["Thank you for dining with us", "Chicken curry 12.50", "Total 25.00"])?.languageCode == "en")
        #expect(ReceiptTranslation.detectLanguage(["12.50", "1,234", "09/10/2026"]) == nil)
    }

    @Test func onlyWordsAreSentNeverAmounts() {
        let jobs = ReceiptTranslation.jobs(for: draft(), target: Locale.Language(identifier: "en"))
        #expect(jobs.map(\.text) == ["自由席券", "緑茶", "JR東海 領収書", "自由席券"])
        #expect(!jobs.contains { $0.text.contains("4,960") || $0.text.contains("1234") })
    }

    @Test func answersLandOnTheirLinesAndAreNotAskedForAgain() {
        var receipt = draft()
        let english = Locale.Language(identifier: "en")
        let jobs = ReceiptTranslation.jobs(for: receipt, target: english)
        let answers = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, "EN " + $0.text) })
        ReceiptTranslation.apply(answers, to: &receipt, language: english)

        #expect(receipt.items[0].translatedName == "EN 自由席券")
        #expect(receipt.items[0].translatedLanguage == "en")
        #expect(receipt.items[1].translatedName == nil)
        #expect(receipt.rows[0].translation == "EN JR東海 領収書")
        #expect(receipt.rows[2].translation == nil)
        #expect(ReceiptTranslation.jobs(for: receipt, target: english).isEmpty)

        // Another language starts over.
        #expect(ReceiptTranslation.jobs(for: receipt, target: Locale.Language(identifier: "ru")).count == jobs.count)
        ReceiptTranslation.clear(&receipt)
        #expect(receipt.items.allSatisfy { $0.translatedName == nil })
        #expect(receipt.rows.allSatisfy { $0.translation == nil })
    }

    @Test func sameLanguageIgnoresRegionsButNotScripts() {
        #expect(Languages.same(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en-GB")))
        #expect(Languages.same(Locale.Language(identifier: "ja"), Locale.Language(identifier: "ja-JP")))
        #expect(!Languages.same(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
        #expect(!Languages.same(Locale.Language(identifier: "ja"), Locale.Language(identifier: "en")))
        #expect(Languages.language(nil) == Languages.phone)
        #expect(Languages.language("de").languageCode == "de")
    }

    @Test func translatedAmountsAreShownAsPrinted() {
        let rows = receiptRows("自由席券  ¥4,960 A")
        #expect(TranslatedReceiptView.amount(in: rows[0]) == "¥4,960")
    }
}
