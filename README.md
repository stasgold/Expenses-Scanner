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

**Stages 1–3** are in place: trips and balances, exchange rates, and receipt scanning.

- **Trips** with a home currency and the people on them. Swipe a trip to rename or delete it.
- **Scan a receipt** with the camera (edges found and straightened, several pages for a long one) or
  **choose a photo**. The phone reads it: items, quantities, subtotal, tax (added on top or already
  included), tip, service charge, discounts, the total, the currency and the date, in about 20 languages
  and with either decimal style.
- **Check it** before saving: the photo (tap ⌖ beside a line to see where it was read), every line
  editable, a chip per person to say who had what (everyone, until you change it), the extras shared by
  what each person had or equally, a warning when the lines don't add up to the receipt's total, and each
  person's share. Saved receipts reopen in the same screen.
- **Typed-in expenses** for everything without a receipt: amount, currency, date, who paid, and shares
  (2 counts double, 0 leaves someone out).
- **Exchange rates fetched automatically** for each expense's day: European Central Bank rates via
  Frankfurter, and fawazahmed0's currency-api for the currencies the ECB doesn't publish (VND and ~170
  more). Saved on the phone: past days are never fetched twice, today's are refreshed after 12 hours, and
  offline the nearest saved day stands in (marked "older rate") until a fresh one arrives. A rate you type
  yourself (say, your card's) always wins.
- **Balances** in the home currency: paid, share and net per person, the fewest payments to settle up,
  and *Mark as paid*.
- **Share** a trip as plain text.

Next: translating the bill (stage 4) and finer item assignment (stage 5: shares per item, tap a person
then their items).

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
│   ├── ReceiptDraft.swift         A scanned receipt being checked
│   └── TripShareFormatter.swift   Plain-text export
├── Receipts/
│   ├── ReceiptScanner.swift       Document camera, Vision text recognition, page stacking
│   └── ReceiptParser.swift        Rows from text positions; items, extras, total, currency, date
├── Rates/
│   ├── ExchangeRates.swift        Providers (Frankfurter, currency-api), cache, rate service
│   └── RateUpdater.swift          Fills in rates for expenses waiting for one
├── Views/                         Trips, trip (expenses | balances), receipt check, expense editor, people
├── Theme/ParticipantPalette.swift The eight person colours (light + dark), shared with Total Scoreboard
├── Localization/L10n.swift        Every user-facing string, English fallback
└── Resources/                     Asset catalog (icon, accent colour)
ExpensesScannerTests/              Money, split, ledger, rates, receipt parsing, Vision end-to-end, store, migration
tools/make_app_icon.py             Draws the app icon (pip install pillow)
```

## Changing the database schema

Trips must never be lost on update, so the store has no destructive fallback:

1. Copy `ExpensesSchemaV1` to `ExpensesSchemaV2` in `Models.swift` and make your changes in the copy.
2. Point the type aliases at V2.
3. Add V2 to `ExpensesMigrationPlan.schemas` and a stage (`.lightweight` or `.custom`) to `stages`.
4. Extend `MigrationTests` so a store from every older version still opens with nothing lost.
