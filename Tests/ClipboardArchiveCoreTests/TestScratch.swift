import Foundation

/// Scratch folders to remove when the test process exits.
///
/// Several suites hand out a temporary folder per test and never removed it,
/// which left a couple of hundred megabytes behind on every run. A folder
/// registered here is removed at exit, whether or not the test that made it
/// passed.
enum TestScratch {
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var folders: [URL] = []

        private init() {
            atexit {
                TestScratch.removeAll()
            }
        }

        func add(_ url: URL) {
            lock.lock()
            folders.append(url)
            lock.unlock()
        }

        func drain() -> [URL] {
            lock.lock()
            defer { lock.unlock() }
            let all = folders
            folders = []
            return all
        }
    }

    static func remember(_ url: URL) {
        Registry.shared.add(url)
    }

    fileprivate static func removeAll() {
        // Newest first, so a folder made inside another goes before it.
        for folder in Registry.shared.drain().reversed() {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
