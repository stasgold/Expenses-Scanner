import SwiftData
import SwiftUI

@main
struct ExpensesScannerApp: App {
    /// One database for the whole app. Opening it can only fail on a missing schema migration,
    /// which must surface during development rather than wipe anyone's trip.
    private let container: ModelContainer = {
        do {
            return try ModelContainer.expenses()
        } catch {
            fatalError("Could not open the expenses database: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TripsListView()
        }
        .modelContainer(container)
    }
}
