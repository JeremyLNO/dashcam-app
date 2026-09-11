import Foundation
import SwiftData

/// Builds the SwiftData container.
///
/// The store holds metadata only — sessions, segments, events, GPS samples. Video bytes
/// live on disk under `StorageLocations.recordingsRoot` and are referenced by relative
/// path. Putting media blobs in the database would make every library query pay for
/// gigabytes of data it never reads.
enum PersistenceController {
    static let schema = Schema([
        DriveSession.self,
        VideoSegment.self,
        ProtectedEvent.self,
        LocationSample.self,
    ])

    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        // SwiftData puts its store in Application Support, which does not exist in a
        // freshly installed container — it will not create the directory itself, and the
        // failure surfaces as an opaque "sandbox access denied" from CoreData.
        _ = StorageLocations.applicationSupport
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A store that cannot be opened is almost always an incompatible schema left
            // by a previous build. Recording is the product; losing the metadata index is
            // survivable, refusing to launch is not. Start clean and let RecoveryManager
            // re-adopt whatever files are still on disk.
            Log.storage.error("Persistent store unavailable (\(error.localizedDescription, privacy: .public)), falling back to a fresh store")
            StorageLocations.removeStoreFiles()
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                // In-memory keeps the app usable for this launch rather than crashing.
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                // swiftlint:disable:next force_try
                return try! ModelContainer(for: schema, configurations: [memory])
            }
        }
    }
}
