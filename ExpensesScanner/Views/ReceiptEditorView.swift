import SwiftUI
import Translation
import UIKit

/// Review a scanned receipt (or edit a saved one): the photo, every line and who had it, the extras,
/// and a check against the printed total.
struct ReceiptEditorView: View {
    let isNew: Bool
    let participants: [ParticipantSnapshot]
    let homeCurrency: CurrencyCode
    /// Remembers the language picked here for the trip's next receipts.
    let onTargetLanguage: (String?) -> Void
    let onSave: (ReceiptExpenseDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReceiptExpenseDraft
    @State private var rateText: String
    @State private var selectedItem: UUID?
    @State private var photoExpanded = false
    /// The lines as the scanner read them; while they're untouched, changing the currency reads again.
    @State private var readItems: [ReceiptItemDraft]
    /// The language to translate into (BCP 47); nil follows the phone.
    @State private var targetLanguage: String?
    @State private var translation: TranslationSession.Configuration?
    @State private var translationState = TranslationState.idle
    @State private var showTranslatedReceipt = false

    private enum TranslationState: Equatable {
        case idle, translating, done, sameLanguage, unavailable, failed
    }

    init(
        isNew: Bool,
        participants: [ParticipantSnapshot],
        homeCurrency: CurrencyCode,
        draft: ReceiptExpenseDraft,
        targetLanguage: String?,
        onTargetLanguage: @escaping (String?) -> Void,
        onSave: @escaping (ReceiptExpenseDraft) -> Void
    ) {
        self.isNew = isNew
        self.participants = participants
        self.homeCurrency = homeCurrency
        self.onTargetLanguage = onTargetLanguage
        self.onSave = onSave
        _draft = State(initialValue: draft)
        _targetLanguage = State(initialValue: targetLanguage)
        _rateText = State(initialValue: draft.rateToHome.map(Money.rateText) ?? "")
        _readItems = State(initialValue: draft.items)
    }

    private var isForeign: Bool { draft.currency.uppercased() != homeCurrency.uppercased() }
    private var everyone: [UUID: Int] { Dictionary(uniqueKeysWithValues: participants.map { ($0.id, 1) }) }
    private var rateInvalid: Bool { isForeign && !rateText.trimmed.isEmpty && Money.parseRate(rateText) == nil }
    private var canSave: Bool { draft.isValid && !rateInvalid }

    var body: some View {
        NavigationStack {
            Form {
                if let photo = draft.photo, let image = UIImage(data: photo) {
                    photoSection(image)
                }
                if !draft.rows.isEmpty || draft.items.contains(where: { $0.name.contains(where: \.isLetter) }) {
                    translationSection
                }
                detailsSection
                itemsSection
                extrasSection
                totalSection
                if isForeign {
                    RateSection(currency: draft.currency, homeCurrency: homeCurrency, date: draft.date, amount: draft.input.total, rateText: $rateText)
                }
            }
            .navigationTitle(isNew ? L10n.newReceipt : L10n.editReceipt)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        guard canSave else { return }
                        var result = draft
                        result.title = draft.title.trimmed
                        result.rateToHome = isForeign ? Money.parseRate(rateText) : nil
                        onSave(result)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: draft.currency) { _, currency in
                readAgain(in: currency)
            }
            .onChange(of: targetLanguage) { _, language in
                ReceiptTranslation.clear(&draft)
                onTargetLanguage(language)
                Task { await startTranslation() }
            }
            .task { await startTranslation() }
            .translationTask(translation) { session in
                await translate(using: session)
            }
            .sheet(isPresented: $showTranslatedReceipt) {
                TranslatedReceiptView(rows: draft.rows)
            }
        }
        // A swipe shouldn't throw away a scan.
        .interactiveDismissDisabled()
    }

    // MARK: Sections

    private func photoSection(_ image: UIImage) -> some View {
        Section {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    GeometryReader { geometry in
                        if let box = draft.items.first(where: { $0.id == selectedItem })?.box {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                                .frame(width: box.width * geometry.size.width + 8, height: box.height * geometry.size.height + 6)
                                .position(x: (box.x + box.width / 2) * geometry.size.width, y: box.midY * geometry.size.height)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: photoExpanded ? 640 : 220)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { photoExpanded.toggle() } }
                .accessibilityLabel(L10n.receiptPhoto)
                .accessibilityAddTraits(.isButton)
        } footer: {
            Text(L10n.receiptPhotoFooter)
        }
    }

    private var detailsSection: some View {
        Section {
            TextField(L10n.receiptTitle, text: $draft.title, prompt: Text(L10n.receiptTitleHint))
            DatePicker(L10n.date, selection: $draft.date, displayedComponents: .date)
            NavigationLink {
                CurrencyPicker(selection: $draft.currency)
            } label: {
                LabeledContent(L10n.currency, value: Money.label(draft.currency))
            }
            Picker(L10n.paidByLabel, selection: $draft.payerID) {
                ForEach(participants) { participant in
                    Text(participant.name).tag(Optional(participant.id))
                }
            }
        }
    }

    private var itemsSection: some View {
        Section {
            if draft.items.isEmpty {
                Text(L10n.noItemsRead)
                    .foregroundStyle(.secondary)
            }
            ForEach($draft.items) { $item in
                ReceiptItemRow(
                    item: $item,
                    currency: draft.currency,
                    participants: participants,
                    isSelected: selectedItem == item.id,
                    onLocate: item.box == nil ? nil : locate(item.id),
                    onRemove: remove(item.id)
                )
            }
            .onDelete { draft.items.remove(atOffsets: $0) }
            Button {
                draft.items.append(ReceiptItemDraft(name: "", amount: 0, weights: everyone))
            } label: {
                Label(L10n.addItem, systemImage: "plus")
            }
        } header: {
            HStack {
                Text(L10n.items)
                Spacer()
                Menu {
                    Button(L10n.everyoneOnAll) {
                        for index in draft.items.indices { draft.items[index].weights = everyone }
                    }
                    Button(L10n.nobodyOnAll) {
                        for index in draft.items.indices { draft.items[index].weights = [:] }
                    }
                } label: {
                    Label(L10n.whoHadWhat, systemImage: "person.2")
                        .labelStyle(.iconOnly)
                }
            }
        } footer: {
            Text(L10n.itemsFooter)
        }
    }

    private var extrasSection: some View {
        Section {
            LabeledContent(L10n.tax) {
                AmountField(title: L10n.tax, value: $draft.tax, currency: draft.currency)
            }
            if draft.tax != 0 {
                Toggle(L10n.taxIncluded, isOn: $draft.taxIncluded)
            }
            LabeledContent(L10n.tip) {
                AmountField(title: L10n.tip, value: $draft.tip, currency: draft.currency)
            }
            LabeledContent(L10n.serviceCharge) {
                AmountField(title: L10n.serviceCharge, value: $draft.service, currency: draft.currency)
            }
            LabeledContent(L10n.discount) {
                AmountField(title: L10n.discount, value: $draft.discount, currency: draft.currency)
            }
            Picker(L10n.shareExtras, selection: $draft.extrasMode) {
                Text(L10n.extrasProportional).tag(ExtrasMode.proportional)
                Text(L10n.extrasEqual).tag(ExtrasMode.equal)
            }
        } header: {
            Text(L10n.extras)
        }
    }

    private var totalSection: some View {
        let total = draft.input.total
        let ids = participants.map(\.id)
        let shares = Split.shares(of: draft.input, participants: ids)
        return Section {
            LabeledContent(L10n.printedTotal) {
                AmountField(title: L10n.printedTotal, value: printedTotal, currency: draft.currency)
            }
            LabeledContent(L10n.addsUpTo, value: Money.format(total, draft.currency))
                .monospacedDigit()
            if let mismatch = draft.mismatch, mismatch != 0 {
                Label(L10n.mismatchWarning(Money.format(abs(mismatch), draft.currency)), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(participants) { participant in
                if let amount = shares.owed[participant.id] {
                    HStack(spacing: 12) {
                        ParticipantBadge(name: participant.name, colorIndex: participant.colorIndex, size: 26)
                        Text(participant.name)
                        Spacer()
                        Text(Money.format(amount, draft.currency))
                            .monospacedDigit()
                    }
                }
            }
            if shares.unassigned != 0 {
                LabeledContent(L10n.notAssigned, value: Money.format(shares.unassigned, draft.currency))
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.total)
        }
    }

    // MARK: Translation

    private var translationSection: some View {
        let target = Languages.language(targetLanguage)
        return Section {
            NavigationLink {
                LanguagePicker(selection: $targetLanguage)
            } label: {
                LabeledContent(L10n.translateTo, value: Languages.name(target))
            }
            if !draft.rows.isEmpty {
                Button {
                    showTranslatedReceipt = true
                } label: {
                    Label(L10n.showTranslatedReceipt, systemImage: "doc.plaintext")
                }
            }
        } header: {
            Text(L10n.translation)
        } footer: {
            translationFooter
        }
    }

    @ViewBuilder
    private var translationFooter: some View {
        let source = draft.sourceLanguage.map { Languages.name(Languages.language($0)) }
        switch translationState {
        case .translating:
            Text(L10n.translating)
        case .done:
            Text(source.map(L10n.translatedFrom) ?? L10n.translationDone)
        case .sameLanguage:
            Text(L10n.sameLanguage(Languages.name(Languages.language(targetLanguage))))
        case .unavailable:
            Text(L10n.translationUnavailable(source ?? "?", Languages.name(Languages.language(targetLanguage))))
                .foregroundStyle(.orange)
        case .failed:
            Text(L10n.translationFailed)
                .foregroundStyle(.orange)
        case .idle:
            Text(L10n.translationFooter)
        }
    }

    /// Works out the receipt's language and, unless it is already the reader's, starts translating.
    private func startTranslation() async {
        let target = Languages.language(targetLanguage)
        let detected = draft.sourceLanguage.map { Languages.language($0) }
            ?? ReceiptTranslation.detectLanguage(draft.rows.map(\.text) + draft.items.map(\.name))
        if let detected, draft.sourceLanguage == nil {
            draft.sourceLanguage = detected.minimalIdentifier
        }
        if let detected, Languages.same(detected, target) {
            translationState = .sameLanguage
            return
        }
        guard !ReceiptTranslation.jobs(for: draft, target: target).isEmpty else {
            translationState = draft.items.contains { $0.translatedName != nil } ? .done : .idle
            return
        }
        if let detected, await LanguageAvailability().status(from: detected, to: target) == .unsupported {
            translationState = .unavailable
            return
        }
        translationState = .translating
        if let current = translation, current.source == detected, current.target == target {
            translation?.invalidate()
        } else {
            translation = TranslationSession.Configuration(source: detected, target: target)
        }
    }

    /// Runs inside `.translationTask`: iOS asks to download the languages first if they aren't on the phone.
    private func translate(using session: TranslationSession) async {
        let target = Languages.language(targetLanguage)
        let jobs = ReceiptTranslation.jobs(for: draft, target: target)
        guard !jobs.isEmpty else {
            translationState = .done
            return
        }
        do {
            let requests = jobs.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            let responses = try await session.translations(from: requests)
            var answers: [String: String] = [:]
            for response in responses {
                if let id = response.clientIdentifier { answers[id] = response.targetText }
            }
            ReceiptTranslation.apply(answers, to: &draft, language: target)
            if draft.sourceLanguage == nil, let source = responses.first?.sourceLanguage {
                draft.sourceLanguage = source.minimalIdentifier
            }
            translationState = .done
        } catch {
            translationState = .failed
        }
    }

    /// Removes a line that isn't a real item (a ticket count, a date, a header the reader took for a price).
    private func remove(_ id: UUID) -> () -> Void {
        {
            withAnimation {
                draft.items.removeAll { $0.id == id }
                if selectedItem == id { selectedItem = nil }
            }
        }
    }

    /// Highlights a line on the photo; tapping it again clears the highlight.
    private func locate(_ id: UUID) -> () -> Void {
        {
            selectedItem = selectedItem == id ? nil : id
        }
    }

    private var printedTotal: Binding<Int64> {
        Binding(
            get: { draft.printedTotal ?? 0 },
            set: { draft.printedTotal = $0 == 0 ? nil : $0 }
        )
    }

    /// The receipt was read in the wrong currency (it didn't say which): read it again in the one picked,
    /// as long as the lines are still as read.
    private func readAgain(in currency: CurrencyCode) {
        guard isNew, !draft.rows.isEmpty, draft.items.map(\.id) == readItems.map(\.id),
              zip(draft.items, readItems).allSatisfy({ $0.name == $1.name && $0.amount == $1.amount })
        else { return }
        let parsed = ReceiptParser.parse(draft.rows, currency: currency, detectCurrency: false)
        let fresh = ReceiptExpenseDraft(
            parsed: parsed, rows: draft.rows, currency: currency, date: draft.date,
            payer: draft.payerID, participants: participants.map(\.id), photo: draft.photo
        )
        draft.items = fresh.items
        draft.tax = fresh.tax
        draft.taxIncluded = fresh.taxIncluded
        draft.tip = fresh.tip
        draft.service = fresh.service
        draft.discount = fresh.discount
        draft.printedTotal = fresh.printedTotal
        readItems = draft.items
        selectedItem = nil
        Task { await startTranslation() }
    }
}

/// One receipt line: its name and amount, and a chip per person to say who had it.
private struct ReceiptItemRow: View {
    @Binding var item: ReceiptItemDraft
    let currency: CurrencyCode
    let participants: [ParticipantSnapshot]
    let isSelected: Bool
    let onLocate: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L10n.itemName, text: $item.name, prompt: Text(L10n.itemName))
                if item.quantity > 1 {
                    Text("×\(item.quantity)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let onLocate {
                    Button(action: onLocate) {
                        Image(systemName: isSelected ? "viewfinder.circle.fill" : "viewfinder")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.showOnPhoto)
                }
                AmountField(title: L10n.amount, value: $item.amount, currency: currency)
                    .frame(maxWidth: 110)
            }
            if let translated = item.translatedName, !translated.isEmpty, translated != item.name {
                Label(translated, systemImage: "character.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.translationOf(translated))
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(participants) { participant in
                            chip(participant)
                        }
                    }
                }
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.removeItem)
            }
        }
        .padding(.vertical, 4)
        // An edited name no longer matches its translation.
        .onChange(of: item.name) { _, _ in
            item.translatedName = nil
            item.translatedLanguage = nil
        }
    }

    private func chip(_ participant: ParticipantSnapshot) -> some View {
        let included = (item.weights[participant.id] ?? 0) > 0
        let accent = ParticipantPalette.accent(for: participant.colorIndex)
        return Button {
            item.weights[participant.id] = included ? 0 : 1
        } label: {
            Text(participant.name)
                .font(.caption.weight(included ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(included ? accent.onContainer : Color.secondary)
                .background(included ? accent.container : Color(.systemGray6), in: Capsule())
                .overlay(Capsule().stroke(included ? Color.clear : Color(.systemGray4), lineWidth: 1))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(participant.name)
        .accessibilityAddTraits(included ? .isSelected : [])
    }
}
