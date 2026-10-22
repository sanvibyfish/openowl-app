import Foundation

/// Persists security-scoped bookmarks for user-selected project directories.
///
/// When a project is added via NSOpenPanel, macOS grants implicit TCC authorization
/// for that URL. By saving a security-scoped bookmark we can re-establish the same
/// authorization on subsequent launches — without triggering a new TCC prompt.
///
/// Without bookmarks the app reconstructs URLs from raw path strings, which macOS
/// treats as a fresh programmatic access and may re-prompt each launch.
@MainActor
final class BookmarkStore {
    private let storeURL: URL
    private var bookmarks: [String: Data] = [:]  // projectID → bookmark Data
    private var activeAccess: [String: URL] = [:] // projectID → currently-accessed URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openowl/bookmarks.plist")
        load()
    }

    /// Returns true if a bookmark exists for the given project ID.
    /// Exposed for testing; use startAccessing to actually restore access.
    func hasBookmark(for projectID: String) -> Bool {
        bookmarks[projectID] != nil
    }

    /// Number of projects holding a live security-scoped session. Exposed for
    /// testing: the restore-on-launch path is otherwise invisible, and it is the
    /// only thing that makes TCC-protected parents readable.
    var activeAccessCount: Int { activeAccess.count }

    // MARK: - Public API

    /// Create and persist a security-scoped bookmark for a user-selected URL.
    /// Call immediately after NSOpenPanel returns a URL.
    func save(projectID: String, url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks[projectID] = data
            persist()
        } catch {
            NSLog("openOwl: [BookmarkStore] bookmark creation failed for %@: %@",
                  url.path, error.localizedDescription)
        }
    }

    /// Resolve a stored bookmark and start a security-scoped access session.
    /// Returns the resolved URL on success, nil if no bookmark exists or resolution fails.
    /// The caller does NOT need to call stopAccessingSecurityScopedResource — BookmarkStore
    /// tracks active sessions and cleans up via stopAll().
    @discardableResult
    func startAccessing(projectID: String) -> URL? {
        // Idempotent: re-starting an already-open session would replace the URL
        // object we later call stopAccessing on, leaking the first extension.
        if let existing = activeAccess[projectID] { return existing }
        guard let data = bookmarks[projectID] else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else { return nil }
            activeAccess[projectID] = url
            if isStale {
                // Refresh stale bookmark while we still have access
                save(projectID: projectID, url: url)
            }
            return url
        } catch {
            NSLog("openOwl: [BookmarkStore] resolution failed for project %@: %@",
                  projectID, error.localizedDescription)
            return nil
        }
    }

    /// Stop the active security-scoped session for a single project.
    func stopAccessing(projectID: String) {
        activeAccess[projectID]?.stopAccessingSecurityScopedResource()
        activeAccess.removeValue(forKey: projectID)
    }

    /// Stop all active sessions. Call from applicationWillTerminate.
    func stopAll() {
        for url in activeAccess.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeAccess.removeAll()
    }

    /// Remove the stored bookmark (e.g., when the project is deleted).
    func remove(projectID: String) {
        stopAccessing(projectID: projectID)
        bookmarks.removeValue(forKey: projectID)
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data)
        else { return }
        bookmarks = decoded
    }

    private func persist() {
        do {
            let data = try PropertyListEncoder().encode(bookmarks)
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("openOwl: [BookmarkStore] persist failed: %@", error.localizedDescription)
        }
    }
}
