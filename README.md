# Expenses Scanner

An iOS app for splitting trip expenses. Photograph a receipt, let the phone read and translate the items,
assign each item to the people who had it, and see who owes whom in one currency, even when the receipt
was in another.

Everything that can run on the phone does: receipt reading (Vision), translation (Apple's Translation
framework) and all the maths. The only network request is for exchange rates, and it carries nothing but
currency codes and a date.

The full plan (features, data model, OCR, translation, rate caching, testing, milestones) is in
[docs/plan.md](docs/plan.md).

## Status

**Stage 1 (foundations)** is in place:

- **Trips** with a home currency and the people on them. Swipe a trip to rename or delete it.
- **Expenses** typed in: title, amount, currency, date, who paid, and who shares it. Steppers give
  someone 2 shares (counts double) or 0 (left out); the editor shows each person's part as you type.
- **Other currencies** with a rate you type in (fetched rates come in stage 2). Without a rate an
  expense waits and is left out of balances, with a notice.
- **Balances** in the home currency: what each person paid, their share, and their net. **Settle up**
  lists the fewest payments that make everyone even; *Mark as paid* records one.
- **Share** a trip as plain text: balances, payments to make, and every expense.

Next: fetched and cached exchange rates (stage 2), receipt scanning (3), translation (4), assigning
items (5).

## How the maths stays exact

- Money is a whole number of the currency's minor unit (`Int64`) plus an ISO 4217 code: cents, yen,
  fils. Decimals per currency follow ISO 4217 (JPY 0, KWD 3). No floating point anywhere.
- Splitting uses the largest-remainder method: parts always add up to the total exactly, and each is
  within one minor unit of its exact share. 10.00 over three is 3.34, 3.33, 3.33.
- A foreign expense is converted once as a whole, then split again, so converted shares still add up
  to the converted total.
- Balances always sum to zero; tests check it on thousands of random trips.

## Building

Requires **Xcode 26** (the project uses Xcode's synchronized folders, so new files are picked up
automatically) and runs on **iOS / iPadOS 18** and newer.

1. Open `ExpensesScanner.xcodeproj`.
2. Pick your team under *Signing & Capabilities* (only needed for a real device).
3. Run the **ExpensesScanner** scheme.

From the terminal:

```bash
xcodebuild test -project ExpensesScanner.xcodeproj -scheme ExpensesScanner \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

GitHub Actions runs the same build and the unit tests on every push (`.github/workflows/ios.yml`).

## TestFlight

`.github/workflows/testflight.yml` archives the app on a GitHub macOS runner, signs it with team
`KK2M84H83J` and uploads it to App Store Connect. It needs an App Store Connect record for
`com.stasgold.expenses.scanner` and three repository secrets (the same kind as Total Scoreboard's):

| Secret          | Value                                                          |
|-----------------|----------------------------------------------------------------|
| `ASC_ISSUER_ID` | Issuer ID shown above the keys list                            |
| `ASC_KEY_ID`    | The key's Key ID                                               |
| `ASC_KEY_P8`    | Full text of the downloaded `AuthKey_XXXX.p8`, BEGIN/END lines included |

Then run **Actions › TestFlight › Run workflow**. The build number is the workflow's run number.

## Project layout

```
ExpensesScanner/
├── App/ExpensesScannerApp.swift   App entry point: opens the database
├── Model/
│   ├── Models.swift               Trip, Participant, Expense, ExpenseItem, ItemShare (SwiftData), schema versions
│   ├── TripStore.swift            Every write goes through here; saves immediately
│   ├── Money.swift                Minor units, currency decimals, formatting, parsing, conversion
│   ├── Split.swift                Largest-remainder splitting, tax/tip/discount sharing, conversion of shares
│   ├── Ledger.swift               Snapshots, balances, settle-up payments
│   └── TripShareFormatter.swift   Plain-text export
├── Views/                         Trips list, trip (expenses | balances), expense editor, people, settings
├── Theme/ParticipantPalette.swift The eight person colours (light + dark), shared with Total Scoreboard
├── Localization/L10n.swift        Every user-facing string, English fallback
└── Resources/                     Asset catalog (icon, accent colour)
ExpensesScannerTests/              Money, split, ledger, store, share-text and migration tests (Swift Testing)
tools/make_app_icon.py             Draws the app icon (pip install pillow)
```

## Changing the database schema

Trips must never be lost on update, so the store has no destructive fallback:

1. Copy `ExpensesSchemaV1` to `ExpensesSchemaV2` in `Models.swift` and make your changes in the copy.
2. Point the type aliases at V2.
3. Add V2 to `ExpensesMigrationPlan.schemas` and a stage (`.lightweight` or `.custom`) to `stages`.
4. Extend `MigrationTests` so a store from every older version still opens with nothing lost.
