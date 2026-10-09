import Foundation
import NaturalLanguage

/// Languages as the app stores them: BCP 47 identifiers ("ja", "en", "zh-Hans"); nil means the phone's.
enum Languages {
    static var phone: Locale.Language { Locale.current.language }

    static func language(_ identifier: String?) -> Locale.Language {
        identifier.map { Locale.Language(identifier: $0) } ?? phone
    }

    /// "Japanese", "English" in the user's language.
    static func name(_ language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
            ?? identifier
    }

    /// Same language for reading purposes: "en-US" and "en-GB" are; "zh-Hans" and "zh-Hant" are not.
    static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        guard let scriptA = a.script, let scriptB = b.script else { return true }
        return scriptA == scriptB
    }
}

/**
 * What to translate on a receipt and where the answers go. Only words are sent: item names are already
 * free of prices, and each line is cut down to its words, so no amount, quantity or code can come back
 * changed. The translating itself is Apple's Translation framework, on the device (see ReceiptEditorView).
 */
enum ReceiptTranslation {
    /// The language a receipt is written in, guessed from its words; nil when unsure.
    static func detectLanguage(_ texts: [String]) -> Locale.Language? {
        let words = texts.map { $0.filter { !$0.isNumber } }.joined(separator: "\n")
        guard words.contains(where: \.isLetter) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.5
        else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// One piece of text to translate; `id` maps the answer back ("item:<uuid>" or "row:<index>").
    struct Job: Equatable {
        var id: String
        var text: String
    }

    /// Everything on the receipt not yet translated into `target`.
    static func jobs(for draft: ReceiptExpenseDraft, target: Locale.Language) -> [Job] {
        let language = target.minimalIdentifier
        var jobs: [Job] = []
        for item in draft.items where item.name.contains(where: \.isLetter) && item.translatedLanguage != language {
            jobs.append(Job(id: "item:\(item.id.uuidString)", text: item.name.trimmed))
        }
        for (index, row) in draft.rows.enumerated() where row.translationLanguage != language {
            let words = ReceiptParser.cleanName(row.text)
            if words.contains(where: \.isLetter) {
                jobs.append(Job(id: "row:\(index)", text: words))
            }
        }
        return jobs
    }

    /// Writes translations (by job id) into the draft, marked with the language they are in.
    static func apply(_ answers: [String: String], to draft: inout ReceiptExpenseDraft, language target: Locale.Language) {
        let language = target.minimalIdentifier
        for index in draft.items.indices {
            if let text = answers["item:\(draft.items[index].id.uuidString)"] {
                draft.items[index].translatedName = text
                draft.items[index].translatedLanguage = language
            }
        }
        for index in draft.rows.indices {
            if let text = answers["row:\(index)"] {
                draft.rows[index].translation = text
                draft.rows[index].translationLanguage = language
            }
        }
    }

    /// Drops every translation, e.g. when the target language changes.
    static func clear(_ draft: inout ReceiptExpenseDraft) {
        for index in draft.items.indices {
            draft.items[index].translatedName = nil
            draft.items[index].translatedLanguage = nil
        }
        for index in draft.rows.indices {
            draft.rows[index].translation = nil
            draft.rows[index].translationLanguage = nil
        }
    }
}
