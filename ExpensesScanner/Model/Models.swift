import Foundation
import SwiftData

// The app always works with the latest schema version through these aliases.
typealias Trip = ExpensesSchemaV1.Trip
typealias Participant = ExpensesSchemaV1.Participant
typealias Expense = ExpensesSchemaV1.Expense
typealias ExpenseItem = ExpensesSchemaV1.ExpenseItem
typealias ItemShare = ExpensesSchemaV1.ItemShare

/**
 * On-device store for trips, people and expenses.
 *
 * Expenses must survive app updates, so the schema is versioned:
 *  - every schema change adds a new `ExpensesSchemaVn` (copy the models, then edit the copy),
 *  - the aliases above move to the new version,
 *  - `ExpensesMigrationPlan` lists every version plus a stage for each step.
 * There is no "delete the store on failure" fallback: a missing migration fails loudly during
 * development instead of silently wiping someone's trip.
 *
 * Money is stored as whole minor units (`Int64`, see `Money`); rates as text so no digit is lost.
 * People are referenced by `uuid` from expenses and shares rather than by relationship, so removing
 * someone never cascades into an expense.
 */
enum ExpensesSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Trip.self, Participant.self, Expense.self, ExpenseItem.self, ItemShare.self]
    }

    /// A trip groups the people travelling together and everything they spend.
    @Model
    final class Trip {
        /// Stable identity for navigation and lookups.
        var uuid: UUID = UUID()
        var name: String = ""
        /// Balances are settled in this currency; foreign expenses are converted into it.
        var homeCurrency: String = "USD"
        /// BCP 47 language that receipts are translated into; nil follows the device language.
        var targetLanguage: String?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        @Relationship(deleteRule: .cascade, inverse: \Participant.trip)
        var participants: [Participant] = []
        @Relationship(deleteRule: .cascade, inverse: \Expense.trip)
        var expenses: [Expense] = []

        init(name: String, homeCurrency: String) {
            self.name = name
            self.homeCurrency = homeCurrency
        }
    }

    /// Someone on the trip.
    @Model
    final class Participant {
        var uuid: UUID = UUID()
        var name: String = ""
        var position: Int = 0
        /// Index into the accent palette; keeps a person's colour stable across restarts.
        var colorIndex: Int = 0
        var trip: Trip?

        init(name: String, position: Int, colorIndex: Int) {
            self.name = name
            self.position = position
            self.colorIndex = colorIndex
        }
    }

    /// One thing paid for: a receipt, a typed-in amount, or a payment between two people.
    @Model
    final class Expense {
        var uuid: UUID = UUID()
        var title: String = ""
        var date: Date = Date()
        var createdAt: Date = Date()
        /// ISO 4217 code of the amounts below.
        var currency: String = "USD"
        /// `ExpenseKind` raw value.
        var kindRaw: String = "manual"
        /// `Participant.uuid` of whoever paid.
        var payerID: UUID?

        // Amounts in minor units of `currency`.
        var tax: Int64 = 0
        /// VAT-style tax already inside the prices (shown, not added).
        var taxIncluded: Bool = true
        var tip: Int64 = 0
        var service: Int64 = 0
        var discount: Int64 = 0
        /// The total printed on the receipt, to compare with the items.
        var printedTotal: Int64?
        /// `ExtrasMode` raw value.
        var extrasModeRaw: String = "proportional"

        /// One unit of `currency` in the trip's home currency, as exact decimal text ("36.512").
        var rateToHome: String?
        /// The day the rate is for (may be the business day before the expense's date).
        var rateDate: Date?
        /// `RateSource` raw value.
        var rateSourceRaw: String?
        var rateFetchedAt: Date?

        // Receipt scans.
        /// BCP 47 language the receipt is written in.
        var sourceLanguage: String?
        @Attribute(.externalStorage)
        var photo: Data?
        /// JSON of the recognised lines (text, box, translation), for the translated-receipt view.
        var ocrLines: Data?

        var trip: Trip?
        @Relationship(deleteRule: .cascade, inverse: \ExpenseItem.expense)
        var items: [ExpenseItem] = []

        init(title: String, date: Date, currency: String, kindRaw: String) {
            self.title = title
            self.date = date
            self.currency = currency
            self.kindRaw = kindRaw
        }
    }

    /// One line of an expense. A manual expense or transfer has exactly one.
    @Model
    final class ExpenseItem {
        var uuid: UUID = UUID()
        /// As printed on the receipt (or typed).
        var name: String = ""
        var translatedName: String?
        var translatedLanguage: String?
        /// The user changed the translation by hand; automatic re-translation leaves it alone.
        var nameEdited: Bool = false
        /// Line total in minor units of the expense's currency.
        var amount: Int64 = 0
        var quantity: Int = 1
        var position: Int = 0
        // Where the line sits on the receipt photo, normalised 0…1 with the origin at the top left.
        var boxX: Double?
        var boxY: Double?
        var boxWidth: Double?
        var boxHeight: Double?
        var expense: Expense?
        @Relationship(deleteRule: .cascade, inverse: \ItemShare.item)
        var shares: [ItemShare] = []

        init(name: String, amount: Int64, position: Int) {
            self.name = name
            self.amount = amount
            self.position = position
        }
    }

    /// One person's part of an item.
    @Model
    final class ItemShare {
        /// `Participant.uuid`.
        var participantID: UUID = UUID()
        /// 1 is a normal share, 2 counts double.
        var weight: Int = 1
        var item: ExpenseItem?

        init(participantID: UUID, weight: Int) {
            self.participantID = participantID
            self.weight = weight
        }
    }
}

/// Add one stage per schema bump, e.g. `.lightweight(fromVersion: V1.self, toVersion: V2.self)`.
enum ExpensesMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ExpensesSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

extension ModelContainer {
    /// The app's database. `inMemory` gives tests and previews a throwaway copy.
    static func expenses(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: ExpensesSchemaV1.self)
        let configuration = ModelConfiguration("Expenses", schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, migrationPlan: ExpensesMigrationPlan.self, configurations: [configuration])
    }

    /// Opens (and migrates) a store at an explicit location; lets tests upgrade an old database.
    static func expenses(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: ExpensesSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, migrationPlan: ExpensesMigrationPlan.self, configurations: [configuration])
    }
}

// MARK: - Typed accessors and ordering

extension Trip {
    /// People in the order they were added, skipping any deleted but not yet saved.
    var orderedParticipants: [Participant] {
        participants.filter { !$0.isDeleted }.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    /// Newest first: by date, then by when it was entered.
    var orderedExpenses: [Expense] {
        expenses.filter { !$0.isDeleted }.sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
    }

    func participant(_ id: UUID?) -> Participant? {
        guard let id else { return nil }
        return orderedParticipants.first { $0.uuid == id }
    }
}

extension Expense {
    var kind: ExpenseKind {
        get { ExpenseKind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }

    var extrasMode: ExtrasMode {
        get { ExtrasMode(rawValue: extrasModeRaw) ?? .proportional }
        set { extrasModeRaw = newValue.rawValue }
    }

    var rateSource: RateSource? {
        get { rateSourceRaw.flatMap(RateSource.init(rawValue:)) }
        set { rateSourceRaw = newValue?.rawValue }
    }

    var rate: Decimal? {
        get { Money.rate(fromText: rateToHome) }
        set { rateToHome = newValue.map(Money.rateText) }
    }

    /// Lines in receipt order, skipping any deleted but not yet saved.
    var orderedItems: [ExpenseItem] {
        items.filter { !$0.isDeleted }.sorted { $0.position < $1.position }
    }

    var input: ExpenseInput {
        ExpenseInput(
            lines: orderedItems.map { item in
                LineInput(
                    amount: item.amount,
                    shares: item.shares
                        .filter { !$0.isDeleted }
                        .sorted { $0.participantID.uuidString < $1.participantID.uuidString }
                        .map { ShareInput(participant: $0.participantID, weight: $0.weight) }
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

    var total: Int64 { input.total }

    /// In another currency, with no rate the user typed, and no fresh fetched one yet.
    var needsRate: Bool {
        guard let home = trip?.homeCurrency, currency != home, rateSource != .manual else { return false }
        return rate == nil || rateSource == .cachedFallback
    }
}

extension ExpenseItem {
    var box: OCRBox? {
        get {
            guard let boxX, let boxY, let boxWidth, let boxHeight else { return nil }
            return OCRBox(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        }
        set {
            boxX = newValue?.x
            boxY = newValue?.y
            boxWidth = newValue?.width
            boxHeight = newValue?.height
        }
    }
}
