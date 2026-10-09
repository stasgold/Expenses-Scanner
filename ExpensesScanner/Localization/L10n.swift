import Foundation

/**
 * Every user-facing string, with its English text as the fallback. Keys are stable so a string catalog
 * (Localizable.xcstrings) can add the other languages later without touching any view.
 */
enum L10n {
    // MARK: General

    static var add: String { tr("add", "Add") }
    static var cancel: String { tr("cancel", "Cancel") }
    static var create: String { tr("create", "Create") }
    static var delete: String { tr("delete", "Delete") }
    static var done: String { tr("done", "Done") }
    static var edit: String { tr("edit", "Edit") }
    static var more: String { tr("more", "More") }
    static var ok: String { tr("ok", "OK") }
    static var rename: String { tr("rename", "Rename") }
    static var save: String { tr("save", "Save") }
    static var share: String { tr("share", "Share") }
    static var view: String { tr("view", "View") }

    // MARK: Trips

    static var tripsTitle: String { tr("trips_title", "Trips") }
    static var tripsEmptyTitle: String { tr("trips_empty_title", "No trips yet") }
    static var tripsEmptySubtitle: String { tr("trips_empty_subtitle", "Create a trip, add the people on it, and keep track of who paid for what.") }
    static var newTrip: String { tr("new_trip", "New trip") }
    static var renameTrip: String { tr("rename_trip", "Rename trip") }
    static var deleteTrip: String { tr("delete_trip", "Delete trip") }
    static func deleteTripMessage(_ name: String) -> String {
        tr("delete_trip_message", "“%@” and all of its expenses will be permanently deleted.", name)
    }
    static var tripName: String { tr("trip_name", "Trip name") }
    static var tripNameHint: String { tr("trip_name_hint", "e.g. Lisbon 2026") }
    static var untitledTrip: String { tr("untitled_trip", "Untitled trip") }
    static var tripSettings: String { tr("trip_settings", "Trip settings") }
    static var homeCurrency: String { tr("home_currency", "Home currency") }
    static var homeCurrencyFooter: String {
        tr("home_currency_footer", "Balances are settled in this currency. Expenses in other currencies are converted into it.")
    }
    static var homeCurrencyChangeWarning: String {
        tr("home_currency_change_warning", "Changing it drops every exchange rate on this trip. Expenses in other currencies are left out of balances until they have a new rate.")
    }
    /// "3 people · 5 expenses"
    static func tripSummary(_ people: String, _ expenses: String) -> String {
        tr("trip_summary", "%1$@ · %2$@", people, expenses)
    }
    static func peopleCount(_ count: Int) -> String {
        count == 1 ? tr("people_count_one", "1 person") : tr("people_count_other", "%lld people", count)
    }
    static func expenseCount(_ count: Int) -> String {
        count == 1 ? tr("expense_count_one", "1 expense") : tr("expense_count_other", "%lld expenses", count)
    }
    static func spentTotal(_ amount: String) -> String { tr("spent_total", "Spent: %@", amount) }

    // MARK: People

    static var people: String { tr("people", "People") }
    static var addPeople: String { tr("add_people", "Add people") }
    static var addPerson: String { tr("add_person", "Add a person") }
    static var personName: String { tr("person_name", "Name") }
    static var renamePerson: String { tr("rename_person", "Rename") }
    static var removePerson: String { tr("remove_person", "Remove from trip") }
    static func removePersonMessage(_ name: String) -> String {
        tr("remove_person_message", "%@ will be taken off this trip and out of every split they were in.", name)
    }
    static var cannotRemoveTitle: String { tr("cannot_remove_title", "Can’t remove") }
    static func cannotRemoveMessage(_ name: String) -> String {
        tr("cannot_remove_message", "%@ paid for something or took part in a payment. Delete those expenses first.", name)
    }
    static var peopleFooter: String { tr("people_footer", "Everyone who shares costs on this trip.") }
    static var newTripPeopleFooter: String { tr("new_trip_people_footer", "You can add more people later.") }
    static var noPeopleSubtitle: String { tr("no_people_subtitle", "Add the people on this trip first.") }

    // MARK: Expenses

    static var expenses: String { tr("expenses", "Expenses") }
    static var noExpensesTitle: String { tr("no_expenses_title", "No expenses yet") }
    static var noExpensesSubtitle: String { tr("no_expenses_subtitle", "Add what you spend and the app works out who owes whom.") }
    static var addExpense: String { tr("add_expense", "Add expense") }
    static var newExpense: String { tr("new_expense", "New expense") }
    static var editExpense: String { tr("edit_expense", "Edit expense") }
    static var deleteExpense: String { tr("delete_expense", "Delete expense") }
    static func deleteExpenseMessage(_ title: String) -> String {
        tr("delete_expense_message", "“%@” will be permanently deleted.", title)
    }
    static var untitledExpense: String { tr("untitled_expense", "Expense") }
    static var expenseTitle: String { tr("expense_title", "What was it?") }
    static var expenseTitleHint: String { tr("expense_title_hint", "e.g. Dinner, taxi, tickets") }
    static var amount: String { tr("amount", "Amount") }
    static var amountError: String { tr("amount_error", "Enter an amount like 12.50.") }
    static var currency: String { tr("currency", "Currency") }
    static var date: String { tr("date", "Date") }
    static var paidByLabel: String { tr("paid_by_label", "Paid by") }
    static func paidBy(_ name: String) -> String { tr("paid_by", "paid by %@", name) }
    static var splitBetween: String { tr("split_between", "Split between") }
    static var everyone: String { tr("everyone", "Everyone") }
    static var nobody: String { tr("nobody", "Nobody") }
    static var notIncluded: String { tr("not_included", "Not included") }
    static var oneShare: String { tr("one_share", "1 share") }
    static func sharesCount(_ count: Int) -> String { tr("shares_count", "%lld shares", count) }
    static var sharesFooter: String { tr("shares_footer", "Give someone 2 shares if they count double, or 0 to leave them out.") }

    // MARK: Exchange rates

    static var exchangeRate: String { tr("exchange_rate", "Exchange rate") }
    /// "1 THB ="
    static func rateLabel(_ currency: String) -> String { tr("rate_label", "1 %@ =", currency) }
    static func rateFooter(_ home: String) -> String {
        tr("rate_footer", "What one unit is worth in %@. Leave it empty and the expense waits for a rate before it counts in balances.", home)
    }
    static func rateConverted(_ amount: String) -> String { tr("rate_converted", "That’s %@ at this rate.", amount) }
    static var rateError: String { tr("rate_error", "Enter a rate like 0.92.") }
    static var noRateYet: String { tr("no_rate_yet", "no rate yet") }

    // MARK: Balances

    static var balances: String { tr("balances", "Balances") }
    static func balancesIn(_ currency: String) -> String { tr("balances_in", "Balances in %@", currency) }
    /// "Paid €40.00 · Share €25.00"
    static func paidAndShare(_ paid: String, _ share: String) -> String {
        tr("paid_and_share", "Paid %1$@ · Share %2$@", paid, share)
    }
    static var settleUp: String { tr("settle_up", "Settle up") }
    static var everyoneEven: String { tr("everyone_even", "Everyone is even.") }
    static var shareNoPeople: String { tr("share_no_people", "(nobody yet)") }
    /// "Ben → Ann"
    static func transferLine(_ from: String, _ to: String) -> String { tr("transfer_line", "%1$@ → %2$@", from, to) }
    /// "Ben paid Ann"
    static func transferTitle(_ from: String, _ to: String) -> String { tr("transfer_title", "%1$@ paid %2$@", from, to) }
    static var markPaid: String { tr("mark_paid", "Mark as paid") }
    static func markPaidMessage(_ from: String, _ to: String, _ amount: String) -> String {
        tr("mark_paid_message", "Record that %1$@ paid %2$@ %3$@.", from, to, amount)
    }
    static func pendingRateNotice(_ count: Int) -> String {
        count == 1
            ? tr("pending_rate_notice_one", "1 expense has no exchange rate yet and isn’t counted.")
            : tr("pending_rate_notice_other", "%lld expenses have no exchange rate yet and aren’t counted.", count)
    }
    static func missingPayerNotice(_ count: Int) -> String {
        count == 1
            ? tr("missing_payer_notice_one", "1 expense has nobody set as the payer and isn’t counted.")
            : tr("missing_payer_notice_other", "%lld expenses have nobody set as the payer and aren’t counted.", count)
    }
    static func unassignedNotice(_ amount: String) -> String {
        tr("unassigned_notice", "%@ isn’t assigned to anyone yet and isn’t counted.", amount)
    }

    /// Looks the key up in the app's strings; falls back to the English text.
    private static func tr(_ key: String, _ english: String, _ args: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: english, table: nil)
        return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
    }
}
