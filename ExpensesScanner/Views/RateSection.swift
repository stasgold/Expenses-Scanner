import SwiftUI

/**
 * The exchange-rate part of an expense form. Left empty, the app uses the rate it fetches for the
 * expense's day (shown as the placeholder and in the footer); typed in, the user's rate wins, e.g. the
 * one their card actually charged.
 */
struct RateSection: View {
    let currency: CurrencyCode
    let homeCurrency: CurrencyCode
    let date: Date
    /// The expense's total in `currency`, for the "that's … at this rate" line.
    let amount: Int64?
    @Binding var rateText: String

    @State private var automatic: RateQuote?
    @State private var looking = false

    private var typed: Decimal? { Money.parseRate(rateText) }
    private var invalid: Bool { !rateText.trimmed.isEmpty && typed == nil }

    var body: some View {
        Section {
            HStack {
                Text(L10n.rateLabel(currency))
                TextField(L10n.exchangeRate, text: $rateText, prompt: Text(automatic.map { Self.text($0.rate) } ?? "0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(homeCurrency)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.exchangeRate)
        } footer: {
            footer
        }
        .task(id: "\(currency)|\(homeCurrency)|\(ExchangeRates.day(date))") {
            automatic = nil
            looking = true
            automatic = await RateService.shared.rate(from: currency, to: homeCurrency, on: date)
            looking = false
        }
    }

    @ViewBuilder
    private var footer: some View {
        if invalid {
            Text(L10n.rateError).foregroundStyle(.red)
        } else if let typed {
            Text(L10n.typedRate(converted(at: typed)))
        } else if let automatic {
            let day = ExchangeRates.date(fromDay: automatic.day)?.formatted(date: .abbreviated, time: .omitted) ?? automatic.day
            if automatic.source == .cachedFallback {
                Text(L10n.offlineRateFooter(day, converted(at: automatic.rate)))
            } else {
                Text(L10n.automaticRateFooter(day, converted(at: automatic.rate)))
            }
        } else if looking {
            Text(L10n.rateLooking)
        } else {
            Text(L10n.rateUnavailable)
        }
    }

    private func converted(at rate: Decimal) -> String {
        Money.format(Money.convert(amount ?? 0, from: currency, to: homeCurrency, rate: rate), homeCurrency)
    }

    /// "36.512", "0.0274": enough digits to read, never scientific notation.
    static func text(_ rate: Decimal) -> String {
        rate.formatted(.number.precision(.significantDigits(1...6)))
    }
}

/// An amount typed in the currency's own format. Writes back whenever the text reads as an amount;
/// empty means 0. Turns red while the text isn't an amount.
struct AmountField: View {
    let title: String
    @Binding var value: Int64
    let currency: CurrencyCode

    @State private var text = ""

    private var invalid: Bool { !text.trimmed.isEmpty && Money.parse(text, currency) == nil }

    var body: some View {
        TextField(title, text: $text, prompt: Text(Money.editableText(0, currency)))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .foregroundStyle(invalid ? Color.red : Color.primary)
            .onAppear { text = Self.text(value, currency) }
            .onChange(of: text) { _, newText in
                if newText.trimmed.isEmpty {
                    value = 0
                } else if let parsed = Money.parse(newText, currency) {
                    value = parsed
                }
            }
            .onChange(of: currency) { _, newCurrency in
                text = Self.text(value, newCurrency)
            }
            .onChange(of: value) { _, newValue in
                // Changed from outside (the receipt was read again): show it, unless it's what's typed.
                if Money.parse(text, currency) != newValue && !(newValue == 0 && text.trimmed.isEmpty) {
                    text = Self.text(newValue, currency)
                }
            }
    }

    private static func text(_ value: Int64, _ currency: CurrencyCode) -> String {
        value == 0 ? "" : Money.editableText(value, currency)
    }
}
