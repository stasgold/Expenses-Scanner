# Expenses Scanner

An iOS app for splitting trip expenses. Photograph a receipt, let the phone read and translate the items,
assign each item to the people who had it, and see who owes whom in one currency, even when the receipt
was in another.

Everything that can run on the phone does: receipt reading (Vision), translation (Apple's Translation
framework) and all the maths. The only network request is for exchange rates, and it carries nothing but
currency codes and a date.

- **Bundle ID**: `com.stasgold.expenses.scanner`
- **Requires**: iOS / iPadOS 18 or newer
- **Plan**: [docs/plan.md](docs/plan.md) covers the features, data model, OCR, translation, exchange-rate
  caching, testing and milestones.

Work in progress: nothing is built yet.
