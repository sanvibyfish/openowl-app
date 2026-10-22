import Testing
import Foundation
@testable import openOwl

/// Tests for BookmarkStore — security-scoped bookmark persistence.
///
/// Each test uses an isolated storeURL in tmp so the real ~/.openowl/bookmarks.plist
/// is never touched and tests don't interfere with each other.
@Suite("BookmarkStore")
struct BookmarkStoreTests {

    // MARK: - Helpers

    /// Returns a fresh BookmarkStore backed by a unique temp plist.
    @MainActor
    private func makeStore() -> (BookmarkStore, URL) {
        let plist = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmarks-test-\(UUID().uuidString).plist")
        return (BookmarkStore(storeURL: plist), plist)
    }

    /// Creates a temporary directory, runs the test body, then cleans up.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    // MARK: - hasBookmark

    @Test @MainActor func hasBookmark_noEntry_returnsFalse() {
        let (store, _) = makeStore()
        #expect(!store.hasBookmark(for: "nonexistent"))
    }

    @Test @MainActor func save_storesBookmark() throws {
        try withTempDir { dir in
            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir)
            #expect(store.hasBookmark(for: "p1"))
        }
    }

    // MARK: - startAccessing

    @Test @MainActor func startAccessing_unknownID_returnsNil() {
        let (store, _) = makeStore()
        #expect(store.startAccessing(projectID: "ghost") == nil)
    }

    @Test @MainActor func startAccessing_savedBookmark_returnsURL() throws {
        try withTempDir { dir in
            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir)
            let resolved = store.startAccessing(projectID: "p1")
            #expect(resolved != nil)
            store.stopAccessing(projectID: "p1")
        }
    }

    @Test @MainActor func startAccessing_resolvedURLPointsToSameDirectory() throws {
        try withTempDir { dir in
            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir)
            let resolved = store.startAccessing(projectID: "p1")
            defer { store.stopAccessing(projectID: "p1") }
            // Standardized paths should match (resolved URL may have different representation)
            #expect(resolved?.standardizedFileURL.path == dir.standardizedFileURL.path)
        }
    }

    /// `ProjectStore` restores access for every project at launch and also
    /// starts it when a project is added. Re-starting an open session would
    /// replace the URL object that `stopAccessing` later releases, leaking the
    /// first extension for the life of the process.
    @Test @MainActor func startAccessing_twiceKeepsOneSession() throws {
        try withTempDir { dir in
            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir)

            let first = store.startAccessing(projectID: "p1")
            #expect(store.activeAccessCount == 1)

            let second = store.startAccessing(projectID: "p1")
            #expect(second?.standardizedFileURL.path == first?.standardizedFileURL.path)
            #expect(store.activeAccessCount == 1)

            store.stopAll()
            #expect(store.activeAccessCount == 0)
        }
    }

    // MARK: - remove

    @Test @MainActor func remove_deletesBookmark() throws {
        try withTempDir { dir in
            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir)
            store.remove(projectID: "p1")
            #expect(!store.hasBookmark(for: "p1"))
        }
    }

    @Test @MainActor func remove_afterStartAccessing_stopsAccessAndDeletes() throws {
        try withTempDir { dir in
            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir)
            _ = store.startAccessing(projectID: "p1")
            store.remove(projectID: "p1")   // should stop access AND delete bookmark
            #expect(!store.hasBookmark(for: "p1"))
            #expect(store.startAccessing(projectID: "p1") == nil)
        }
    }

    // MARK: - stopAll

    @Test @MainActor func stopAll_clearsAllActiveSessions() throws {
        try withTempDir { dir1 in
            let dir2 = FileManager.default.temporaryDirectory
                .appendingPathComponent("openowl-bm2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir2) }

            let (store, _) = makeStore()
            store.save(projectID: "p1", url: dir1)
            store.save(projectID: "p2", url: dir2)
            _ = store.startAccessing(projectID: "p1")
            _ = store.startAccessing(projectID: "p2")
            store.stopAll()  // should not crash and should clear internal state
            // After stopAll, resolving again via same store instance should still work
            // (bookmark data is still present, access was just stopped)
            #expect(store.hasBookmark(for: "p1"))
            #expect(store.hasBookmark(for: "p2"))
        }
    }

    // MARK: - Persistence across instances

    @Test @MainActor func persistence_bookmarkSurvivesNewStoreInstance() throws {
        try withTempDir { dir in
            let plist = FileManager.default.temporaryDirectory
                .appendingPathComponent("bm-persist-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: plist) }

            // First instance: save bookmark
            let store1 = BookmarkStore(storeURL: plist)
            store1.save(projectID: "p1", url: dir)

            // Second instance loading from same plist: bookmark must be present
            let store2 = BookmarkStore(storeURL: plist)
            #expect(store2.hasBookmark(for: "p1"))

            let resolved = store2.startAccessing(projectID: "p1")
            #expect(resolved != nil)
            store2.stopAccessing(projectID: "p1")
        }
    }
}
