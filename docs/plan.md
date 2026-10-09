# Expenses Scanner: plan

Photograph a receipt, let the phone read the items and translate them into your language, assign each
item to the people who had it, and see who owes whom in one currency, even when the receipt was in another. This document is the plan only;
nothing here is built yet.

## Decisions

| # | Question | Answer |
|---|----------|--------|
| 1 | Name | **Expenses Scanner** (decided). iOS cuts home-screen names off at about 12–14 characters and this is 16, so suggest `CFBundleDisplayName` "Expenses", with the full name on the App Store. |
| 2 | Bundle ID | **`com.stasgold.expenses.scanner`** (decided). Needs a new App Store Connect record. Test target: `com.stasgold.expenses.scannerTests`. |
| 3 | Where it lives | **This repository** ([stasgold/Expenses-Scanner](https://github.com/stasgold/Expenses-Scanner)), a standalone Xcode project. CI, TestFlight and App Store workflows, the string tooling and the code conventions are carried over from [Total Scoreboard](https://github.com/stasgold/Universal-Scoreboard-iOS). Scoreboard stays as it is: no camera, no network, integer scores. |
| 4 | Minimum iOS | **18.0**. Translating the bill needs Apple's Translation framework, whose programmatic `TranslationSession` starts at iOS 18. iOS 26's better document OCR is used when present (see OCR). |
| 5 | Languages at launch | **English first** (recommended). Add the other 19 once the strings settle, because receipt keywords per language matter more than UI strings (see Parser). |
| 6 | Android | Out of scope. The data model and algorithms below are platform-neutral, so a Kotlin port can follow them. |

## What the user can do (v1)

1. **Trips.** Create a trip ("Lisbon 2026") with a home currency (the one balances are settled in) and
   the people on it.
2. **Add an expense** three ways: *Scan receipt* (document camera), *Choose photo* (photo library), or
   *Enter manually* (taxi, tickets: a title, an amount, and who shares it).
3. **Review the scan.** The receipt photo sits on top and the items it read are listed below, each with
   its original name and its translation into the target language ("Bacalhau à Brás" → "Salt cod with
   eggs and potatoes"). Every field is editable, and lines can be deleted, merged or added. A banner compares the item sum with the
   printed total ("Items add up to 41.50, receipt says 43.50: check for a missing line").
4. **Assign items.** Tap a person's chip to make them active, then tap the items they had (paint mode).
   An item can have several people, split equally by default or by shares (2:1). *Everyone* and
   *Split the rest equally* are one tap each. Pick who paid.
5. **Tax, tip, service, discounts** are shared out in proportion to each person's items (default) or
   equally (per expense).
6. **Currency.** The expense keeps its own currency (read from the receipt, or chosen) and is converted
   to the trip's home currency at a rate fetched once, cached, and locked onto the expense. The rate is
   shown and can be overridden ("my card charged 1.0842").
7. **Balances.** Each person's paid, owed and net amounts in the home currency, plus the fewest transfers
   that settle everything. *Mark as paid* records a transfer.
8. **Translate the whole bill.** *Show translation* switches the receipt photo to a translated view:
   every line the scanner read, translated, in receipt order, with prices untouched. The target language
   is the trip's (defaults to the device language) and can be changed per trip.
9. **Share** a trip summary as plain text, the same spirit as Scoreboard's share. Item names appear in
   the target language, with the original in brackets.

Not in v1: accounts, syncing between phones, multiple payers on one receipt, budgets, CSV export.

## Architecture

Same style as Scoreboard: SwiftUI, SwiftData, a store struct that owns every write and saves at once,
pure value types for the maths, Swift Testing with an in-memory store. No third-party dependencies.

```
ExpensesScanner/
├── App/ExpensesScannerApp.swift    Opens the database
├── Model/
│   ├── Models.swift                Trip, Participant, Expense, Item, Share (SwiftData) + TripSchemaV1, migration plan
│   ├── TripStore.swift             Every write; saves immediately
│   ├── Money.swift                 Minor-unit amounts, currency digits, formatting, parsing
│   ├── Split.swift                 Largest-remainder allocation, per-person shares, extras
│   ├── Balances.swift              Net balances + settle-up transfers
│   └── TripShareFormatter.swift    Plain-text summary
├── Receipts/
│   ├── ReceiptCapture.swift        VNDocumentCameraViewController + PhotosPicker wrappers
│   ├── TextRecognizer.swift        Vision → [OCRLine]; iOS 26 RecognizeDocumentsRequest when available
│   ├── LineGrouper.swift           Words with boxes → receipt rows
│   └── ReceiptParser.swift         Rows → ReceiptDraft (items, totals, currency, date); pure, no Vision
├── Translation/
│   ├── LanguageDetector.swift      NLLanguageRecognizer over the receipt's text → source language
│   ├── ReceiptTranslator.swift     Batches item names and receipt lines through TranslationSession
│   └── TranslatableText.swift      Splits a line into translatable text and protected tokens (prices, codes)
├── Rates/
│   ├── ExchangeRateProvider.swift  Protocol + Frankfurter implementation
│   ├── RateCache.swift             Actor; JSON file in Caches
│   └── RateService.swift           Cache-first lookup, offline fallback, locking onto expenses
└── Views/                          TripsList, Trip (Expenses | Balances), AddExpense, ReceiptReview,
                                    AssignItems, ExpenseDetail, RateSheet, TranslatedReceipt, Participants
ExpensesScannerTests/         Money, Split, Balances, Parser fixtures, Translation, RateService, Store, Migration
```

`CounterPalette`, `FlowLayout` and `Prompts` are copied from Scoreboard. If both apps keep changing them,
they move into a shared Swift package.

### Data model (TripSchemaV1)

All money is **integer minor units** (`Int64`) plus an ISO 4217 code. Never `Double`. Rates are `Decimal`.

| Model | Fields |
|-------|--------|
| `Trip` | uuid, name, homeCurrency, targetLanguage (BCP 47, default device language), createdAt, updatedAt, participants (cascade), expenses (cascade) |
| `Participant` | uuid, name, colorIndex, position |
| `Expense` | uuid, title, date, currency, payer (Participant), kind (receipt / manual / transfer), itemsTotal, tax, tip, service, discount, printedTotal?, taxIncluded, extrasMode (proportional / equal), rateToHome (Decimal?), rateDate?, rateSource (provider / cachedFallback / manual / same), rateFetchedAt?, sourceLanguage?, ocrLines (JSON: text, box, translation?, translationLanguage?), photo (`@Attribute(.externalStorage)` JPEG, long edge 2000 px), items (cascade) |
| `Item` | uuid, name (as printed), translatedName?, translatedLanguage?, nameEdited (Bool), amount, quantity, position, sourceBox (normalized rect on the photo, optional), shares (cascade) |
| `Share` | participant, weight (Int, default 1) |

Removing a participant who appears in shares or as a payer asks first and reassigns or removes them.
The schema follows the repo's rule: frozen versions, a migration plan, no destructive fallback, and a
`MigrationTests` case from day one.

### Money

- Currency minor digits come from `NumberFormatter` with `currencyCode` set (JPY 0, EUR 2, KWD 3).
  Unit-test a table of codes.
- Formatting uses `Decimal.FormatStyle.Currency` in the user's locale.
- Parsing amounts typed by the user is locale-aware. Parsing amounts from receipts is handled in Parser.

### Split algorithm (largest remainder)

`allocate(total: Int64, weights: [Int]) -> [Int64]`: floor each `total × wᵢ / W`, then hand the leftover
minor units to the largest fractional parts, ties broken by participant position. The shares always add
up exactly to the total. It handles negative totals (discounts, refunds) symmetrically.

Per expense:
1. Each item's amount is allocated over its shares: everyone's item subtotal.
2. Extras (tax if not included, tip, service, minus discount) are allocated with weights = item
   subtotals (proportional) or equal weights.
3. Conversion: convert the expense total once (`round(total × rate × 10^(homeDigits − srcDigits))`,
   half-up), then re-allocate the converted total using step 2's per-person amounts as weights. This way
   per-person converted shares always add up to the converted total, with no stray cent.

Property tests: random totals and weights, sum invariant, every share within one minor unit of exact.

### Balances and settle-up

`net = paid − owed` per person, in home minor units (the sum is 0 by construction; assert it). Settle-up
is greedy: largest debtor pays the largest creditor, repeat. At most n − 1 transfers. *Mark as paid*
adds a `transfer` expense (payer → one participant), so balances update through the same code path.
Unassigned items are excluded from balances and flagged on the trip ("2 items not assigned").

## Receipt OCR

All on-device. No image ever leaves the phone.

**Capture.** `VNDocumentCameraViewController` (VisionKit) gives edge detection, deskew and multi-page,
which matters for long receipts: pages are stitched vertically. `PhotosPicker` covers existing photos,
the simulator and screenshots. `NSCameraUsageDescription` is set in `InfoPlist.xcstrings`.

**Recognition** (`TextRecognizer`). Both produce the same `[OCRLine(text, box, confidence)]`:
- iOS 18–25: `VNRecognizeTextRequest`, `.accurate`, language correction **off** (it "fixes" prices),
  recognition languages from the device's preferred languages plus English.
- iOS 26+: `RecognizeDocumentsRequest`, whose `DocumentObservation` exposes lines and tables. Use its
  lines (and table rows when it finds an item/price table). It sits behind a flag until it beats the
  fallback on the fixture set.

**Grouping** (`LineGrouper`). Receipts are two columns (name … price) that Vision often returns as
separate observations. Words whose vertical centres fall within half the median line height of each
other form a row, ordered left to right.

**Parsing** (`ReceiptParser`, pure Swift, the heart of the feature):
1. Find price tokens: the right-most number in a row matching `-?[\d .,']+\d` with an optional currency
   symbol or code and an optional trailing `-` (discount). The decimal separator is decided **per receipt**
   by majority vote: if most tokens end in `,dd` the comma is decimal. Currency minor digits break ties
   (`1.234` is 1.234 KWD but 1234 HUF).
2. Classify each row by keywords in a per-language table: total / subtotal / tax / VAT / tip / service /
   discount / change / cash / card / ignore. For example TOTAL, SUMME, TOTALE, ИТОГО, 合計, รวม, TỔNG.
   Rows after the grand total (payment, change, card slips) are ignored.
3. Quantity: `2 x 3.50`, `2 @ 3.50`, `3.50 x 2` give quantity and unit price, and the line amount is
   checked against the product.
4. Currency: ISO codes or symbols on the receipt (`€`, `£`, `¥`, `฿`, `₫`, `zł`, `Kč`…). Ambiguous
   ones (`$`, `kr`) and missing ones fall back to the trip's last-used currency, then the device's
   region currency. Always editable.
5. Date: `NSDataDetector` (`.date`). The expense date defaults to it, else today.
6. Tax handling: if items ≈ total, tax lines are informational (VAT-inclusive, as in Europe) and
   `taxIncluded = true`. If items + tax ≈ total, tax is added on top (as in the US).
7. Output `ReceiptDraft` with items, extras, printed total, currency, date, and a `mismatch` amount.

Each item keeps its `sourceBox`. Tapping an item in Review highlights that line on the photo, which makes
checking quick.

**Fixtures.** A DEBUG-only "Export OCR" button saves a receipt's `[OCRLine]` as JSON. Real receipts
(with personal data scrubbed) become `ExpensesScannerTests/Fixtures/*.json` with expected drafts,
so the parser is tested without Vision. Target: 30+ fixtures across at least 8 countries before release.
Measure items correct and total-matches rate, and track them in the test output.

## Translating the bill

Also all on-device, through Apple's **Translation** framework. It is free, needs no key, and works
offline once the language pair is downloaded.

**Source language.** `NLLanguageRecognizer` over all of the receipt's text, ignoring number-only lines.
If it is unsure (confidence < 0.6) or the user disagrees, they can pick the language. That choice is
saved on the expense.

**What is translated.**
- Every item name, which is what the user needs to assign items ("which one was mine?").
- Every OCR line, for the *Show translation* view of the whole bill: headers, notes, "service not
  included", tax lines.
- Never prices, quantities, dates or currency codes. `TranslatableText` cuts those out of a line, sends
  only the words, and stitches the result back around the original numbers. This stops a translation
  model from "localising" `12,50` into `12.50` or dropping a digit.

**How.**
- Availability: `LanguageAvailability().status(from:to:)` returns installed, supported (needs a download)
  or unsupported. Supported pairs get a one-time download prompt, shown by the system the first time a
  translation runs, with a *Not now* option. Unsupported pairs show the original with a short notice.
- Sessions: `.translationTask(configuration)` on the review and translated-receipt screens, which hands
  over a `TranslationSession` (iOS 18). On iOS 26.4+ the background path can also use
  `TranslationSession(installedSource:target:)` for pairs already installed, so items translated after
  a scan don't wait for a screen.
- Batching: one `translations(from:)` call per receipt, each request's `clientIdentifier` set to the
  item's or line's uuid so the answers map back.
- Source and target the same: skip.

**Storage and editing.** The original name is always kept, and the translation sits beside it with its
language. If the user edits a translation, `nameEdited` stops automatic re-translation from overwriting
it. Changing the trip's target language re-translates every unedited name (on a queue, as language
downloads allow).

**Translated receipt view.** A list in receipt order: original line in small type, translation below,
price on the right, the same layout as the paper. Tapping a line highlights it on the photo (reusing
`sourceBox`). An overlay drawn directly over the photo, like Live Text, is a later polish item.

## Currency conversion with a cached rate

**Provider:** [Frankfurter](https://frankfurter.dev). Free, no API key, central-bank data. The v2 API
combines ECB, Bank of England, US Treasury and other banks, so it covers more currencies than the ECB-only
v1. It supports a historical date. Endpoint shape (to verify against the live docs in phase 2):
`GET https://api.frankfurter.dev/v2/rates?base=EUR&date=2026-10-09`. One request returns every
quote for a base and date, so a single call fills the cache for the whole trip. `ExchangeRateProvider`
is a protocol, so a second source (e.g. open.er-api.com) can be added if a needed currency is missing.

**Which rate.** The rate for the expense's date, not today's, so a trip entered afterwards uses the
right rates. Rates come from central-bank reference data. The UI says so, and the manual override is
there for the card's real rate.

**Cache** (`RateCache` actor, one JSON file in `Caches/`):
- Key: provider + base + date → all quotes, fetchedAt.
- Past dates never expire. Today's rates expire after 12 h. Frankfurter publishes once per working day,
  and the response's `date` may be the previous business day (weekends, holidays). Store under the date
  returned **and** the date requested.
- Cross rates are derived from one base (`A→B = (EUR→B) / (EUR→A)`), so one cached base serves every pair.
- The cache is disposable. Losing it only costs a refetch, because each expense locks its own rate.

**Locking.** When an expense is saved, its rate, rateDate, source and fetchedAt are written onto it.
Totals never drift when the cache refreshes. A refresh happens only when the user taps *Update rate*,
changes the expense date or currency, or changes the trip's home currency (asks first, then refetches
for every expense).

**Offline:**
1. A cached rate for the date: use it (`provider`).
2. Otherwise the newest cached rate for the pair: use it, badge "approximate rate from 3 Oct"
   (`cachedFallback`), and replace it automatically next time the app is online, unless the user
   overrode it.
3. Nothing cached: ask for a manual rate, or save with "rate pending". Pending expenses show in the
   original currency and are left out of balances (with a notice) until a rate arrives.

`URLSession` async/await, 10 s timeout, HTTPS only. Requests carry only currency codes and a date, so
the privacy label stays *Data Not Collected*.

## Testing

| Area | How |
|------|-----|
| Money, Split, Balances | Pure unit tests, table-driven, plus property tests for the sum invariants |
| Parser | JSON fixtures → expected `ReceiptDraft`. Synthetic edge cases: comma decimals, 0- and 3-digit currencies, discounts, quantities, VAT-inclusive vs added tax, multi-page |
| Translation | `TranslatableText` round-trips prices, quantities and codes untouched (table tests in several scripts, RTL included). A `Translator` protocol with a fake lets store and view-model tests run without language downloads. Language detection is tested on fixture receipts |
| Rates | `URLProtocol` stub. Covers cache hit, expiry, weekend date shift, offline fallback, cross rates, manual override survives refresh |
| Store | In-memory SwiftData, like `ScoreboardStoreTests` |
| Migration | `TripSchemaV1` store opens. Grows with every schema version |
| UI | One smoke UI test per flow using *Choose photo* with a bundled receipt image (the simulator has no camera) |

CI: `ios.yml` gets a second `xcodebuild test` step for the `ExpensesScanner` scheme. TestFlight and App Store
workflows take the scheme or bundle ID as an input.

## Milestones

Each one ends in a TestFlight build that is useful by itself.

1. **Foundations.** Target, scheme, CI, schema, Money, Split, Balances, store, manual expenses in one
   currency, trips and participants UI, balances and settle-up, share text. *Done when* a trip with
   manual expenses settles correctly and every invariant test passes.
2. **Currencies.** Per-expense currency, provider, cache, locking, offline fallback, rate sheet with
   override, home-currency change. *Done when* a trip mixing EUR, THB and JPY balances in USD offline
   after one online fetch.
3. **Scanning.** Capture, recognition, grouping, parser, review screen with photo highlights, fixture
   suite and DEBUG export. *Done when* the fixture suite passes and real receipts from three countries
   go photo → reviewed items in under a minute.
4. **Translating.** Language detection, protected-token splitting, item-name translation in review,
   translated receipt view, target language per trip, download prompts, edited translations kept.
   *Done when* a Portuguese, a Japanese and a Thai receipt show English item names offline after the
   language download, with every price unchanged.
5. **Assigning.** Paint-mode assignment, shares, *Everyone* / *rest equally*, payer, extras modes,
   unassigned warnings, per-person breakdown per expense. *Done when* a 12-item, 4-person dinner with
   tip is assigned and correct to the cent.
6. **Release polish.** iOS 26 document request behind a measured flag, VoiceOver labels, Dynamic Type,
   iPad layout, localization (19 more languages plus parser keywords), App Store metadata, screenshots
   via the existing workflow, privacy page.

## Risks

| Risk | Mitigation |
|------|------------|
| OCR misreads (thermal paper, creases, odd layouts) | Review is always shown and fully editable. A total-mismatch banner. Line highlights on the photo. Fixtures from real receipts drive parser work |
| Decimal separator ambiguity | Per-receipt majority vote plus currency digits, with tests for each case |
| Rate API down or changed | Protocol behind a provider, locked rates on expenses, cached fallback, manual entry. Never blocks saving |
| Central-bank rate ≠ card rate | Labelled as reference rate, one-tap override |
| Translation garbles a price or quantity | Numbers never reach the translator; they are cut out and stitched back, with tests |
| Short menu words translate badly ("Prato do dia", brand names) | Original always shown beside the translation; translations editable and kept |
| Language not supported or not downloaded | Original shown with a notice; download offered, never forced; the rest of the app works unchanged |
| Rounding disputes | Largest-remainder allocation everywhere, with sums asserted in tests |
| Large photos bloating the store | JPEG at 2000 px long edge in external storage, plus an option to drop photos after settling |
