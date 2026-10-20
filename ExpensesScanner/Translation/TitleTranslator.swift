import Foundation
import Translation

/**
 * Translates the titles of a trip's saved receipts that don't have one in the reader's language yet,
 * from the trip screen. Only languages already on the phone are used, so nothing asks to download.
 */
@MainActor
enum TitleTranslator {
    /// Receipts whose title still needs translating, with the language each is written in.
    static func pending(_ trip: Trip) -> [(expense: Expense, source: Locale.Language)] {
        let target = Languages.language(trip.targetLanguage)
        return trip.orderedExpenses.compactMap { expense in
            guard expense.kind == .receipt else { return nil }
            let text = expense.receiptText
            guard ReceiptTranslation.titleNeedsTranslation(expense.title, saved: text.title, target: target),
                  let source = expense.sourceLanguage.map { Languages.language($0) }
                    ?? ReceiptTranslation.detectLanguage(text.rows.map(\.text) + [expense.title]),
                  !Languages.same(source, target)
            else { return nil }
            return (expense, source)
        }
    }

    /// Changes whenever a title gets translated or the reading language changes.
    static func pendingKey(_ trip: Trip) -> String {
        Languages.language(trip.targetLanguage).minimalIdentifier + ":"
            + pending(trip).map { $0.expense.uuid.uuidString }.joined(separator: ",")
    }

    /// A session for the first waiting language, if it is on the phone.
    static func configuration(for trip: Trip) async -> TranslationSession.Configuration? {
        guard let source = pending(trip).first?.source else { return nil }
        let target = Languages.language(trip.targetLanguage)
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return nil }
        return TranslationSession.Configuration(source: source, target: target)
    }

    /// Translates the waiting titles in the session's language and saves them.
    static func translate(_ trip: Trip, using session: TranslationSession, store: TripStore) async {
        let pending = pending(trip)
        guard let source = pending.first?.source else { return }
        let target = Languages.language(trip.targetLanguage).minimalIdentifier
        let batch = pending.filter { Languages.same($0.source, source) }.map { $0.expense }
        let requests = batch.map { TranslationSession.Request(sourceText: $0.title.trimmed, clientIdentifier: $0.uuid.uuidString) }
        guard let responses = try? await session.translations(from: requests) else { return }
        for response in responses {
            guard let id = response.clientIdentifier, let expense = batch.first(where: { $0.uuid.uuidString == id }) else { continue }
            store.setTitleTranslation(expense, TitleTranslation(source: expense.title.trimmed, text: response.targetText, language: target))
        }
    }
}
