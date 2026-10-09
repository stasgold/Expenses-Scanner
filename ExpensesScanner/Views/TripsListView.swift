import SwiftData
import SwiftUI

/// Navigation value for the trip screen; trips are looked up by their stable `uuid`.
struct TripRoute: Hashable {
    let tripID: UUID
}

/// Home screen: every trip, most recently used first.
struct TripsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Trip.updatedAt, order: .reverse), SortDescriptor(\Trip.createdAt, order: .reverse)])
    private var trips: [Trip]

    @State private var path: [TripRoute] = []
    @State private var showNewTrip = false
    @State private var prompt: TextPrompt?
    @State private var confirmation: Confirmation?

    private var store: TripStore { TripStore(context: context) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trips.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(L10n.tripsTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewTrip = true } label: {
                        Label(L10n.newTrip, systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: TripRoute.self) { route in
                TripView(tripID: route.tripID)
            }
        }
        .sheet(isPresented: $showNewTrip) {
            NewTripSheet { name, currency, people in
                let trip = store.createTrip(name: name, homeCurrency: currency, people: people)
                path.append(TripRoute(tripID: trip.uuid))
            }
        }
        .textPrompt($prompt)
        .confirmation($confirmation)
    }

    private var list: some View {
        List {
            ForEach(trips) { trip in
                NavigationLink(value: TripRoute(tripID: trip.uuid)) {
                    TripRow(trip: trip.snapshot)
                }
                .swipeActions(edge: .trailing) {
                    // Not role: .destructive — that animates the row away before the user confirms.
                    Button { confirmDelete(trip) } label: {
                        Label(L10n.delete, systemImage: "trash")
                    }
                    .tint(.red)
                    Button { rename(trip) } label: {
                        Label(L10n.rename, systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button { rename(trip) } label: { Label(L10n.rename, systemImage: "pencil") }
                    ShareLink(item: TripShareFormatter.text(trip.snapshot), subject: Text(trip.name)) {
                        Label(L10n.share, systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmDelete(trip) } label: {
                        Label(L10n.delete, systemImage: "trash")
                    }
                }
            }
        }
        .animation(.default, value: trips.map(\.uuid))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.tripsEmptyTitle, systemImage: "suitcase")
        } description: {
            Text(L10n.tripsEmptySubtitle)
        } actions: {
            Button(L10n.newTrip) { showNewTrip = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func rename(_ trip: Trip) {
        prompt = TextPrompt(title: L10n.renameTrip, placeholder: L10n.tripName, initialText: trip.name) { name in
            store.updateTrip(trip, name: name, homeCurrency: trip.homeCurrency)
        }
    }

    private func confirmDelete(_ trip: Trip) {
        confirmation = Confirmation(
            title: L10n.deleteTrip,
            message: L10n.deleteTripMessage(trip.name),
            confirmTitle: L10n.delete,
            destructive: true
        ) {
            store.deleteTrip(trip)
        }
    }
}

private struct TripRow: View {
    let trip: TripSnapshot

    var body: some View {
        let spent = Ledger(trip).spent
        HStack(spacing: 16) {
            Image(systemName: "suitcase")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name.isEmpty ? L10n.untitledTrip : trip.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(L10n.tripSummary(L10n.peopleCount(trip.participants.count), L10n.expenseCount(trip.expenses.count)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.format(spent, trip.homeCurrency))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Name, home currency and the people on the trip.
struct NewTripSheet: View {
    let onCreate: (_ name: String, _ currency: CurrencyCode, _ people: [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var currency = Money.localCurrency
    @State private var people: [String] = []
    @State private var newPerson = ""
    @FocusState private var focus: Field?

    private enum Field {
        case name, person
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.tripName, text: $name, prompt: Text(L10n.tripNameHint))
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .person }
                } header: {
                    Text(L10n.tripName)
                }
                Section {
                    NavigationLink {
                        CurrencyPicker(selection: $currency)
                    } label: {
                        LabeledContent(L10n.homeCurrency, value: Money.label(currency))
                    }
                } footer: {
                    Text(L10n.homeCurrencyFooter)
                }
                Section {
                    ForEach(people.indices, id: \.self) { index in
                        Text(people[index])
                    }
                    .onDelete { people.remove(atOffsets: $0) }
                    HStack {
                        TextField(L10n.addPerson, text: $newPerson)
                            .focused($focus, equals: .person)
                            .submitLabel(.done)
                            .onSubmit(addPerson)
                        Button(L10n.add, action: addPerson)
                            .disabled(newPerson.trimmed.isEmpty)
                    }
                } header: {
                    Text(L10n.people)
                } footer: {
                    Text(L10n.newTripPeopleFooter)
                }
            }
            .navigationTitle(L10n.newTrip)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.create) {
                        // A name typed but not yet added still counts.
                        let everyone = people + [newPerson.trimmed].filter { !$0.isEmpty }
                        onCreate(name.trimmed, currency, everyone)
                        dismiss()
                    }
                    .disabled(name.trimmed.isEmpty)
                }
            }
            .onAppear { focus = .name }
        }
    }

    private func addPerson() {
        let person = newPerson.trimmed
        guard !person.isEmpty else { return }
        people.append(person)
        newPerson = ""
        focus = .person
    }
}
