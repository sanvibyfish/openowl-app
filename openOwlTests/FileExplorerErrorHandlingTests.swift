import Testing
import Foundation
@testable import openOwl

/// Tests for the silent-failure fixes in FileExplorerStore:
/// - classifyGitState / mergeGitState correctness (used in loadGitStatus)
/// - GitContext.empty is a safe fallback
/// - sortEntries handles empty input
@Suite("FileExplorer Error Handling")
struct FileExplorerErrorHandlingTests {

    // MARK: - GitContext.empty as safe fallback

    @Test func gitContextEmpty_hasNoEntries() {
        let ctx = FileExplorerStore.GitContext.empty
        #expect(ctx.statusByAbsolutePath.isEmpty)
        #expect(ctx.ignoredExactPaths.isEmpty)
        #expect(ctx.ignoredDirectoryPrefixes.isEmpty)
    }

    @Test func isGitIgnored_emptyContext_returnsFalse() {
        // When git status fails and context falls back to .empty,
        // no file should appear gitignored.
        let ctx = FileExplorerStore.GitContext.empty
        #expect(!FileExplorerStore.isGitIgnored(path: "/project/node_modules/foo.js", gitContext: ctx))
        #expect(!FileExplorerStore.isGitIgnored(path: "/project/.build/debug", gitContext: ctx))
    }

    // MARK: - classifyGitState

    @Test func classifyGitState_staged_added() {
        let change = GitFileChange(path: "src/new.swift", indexStatus: "A", workTreeStatus: " ", section: .staged)
        #expect(FileExplorerStore.classifyGitState(for: change) == .added)
    }

    @Test func classifyGitState_unstaged_modified() {
        let change = GitFileChange(path: "src/old.swift", indexStatus: " ", workTreeStatus: "M", section: .modified)
        #expect(FileExplorerStore.classifyGitState(for: change) == .modified)
    }

    @Test func classifyGitState_staged_deleted() {
        let change = GitFileChange(path: "src/gone.swift", indexStatus: "D", workTreeStatus: " ", section: .staged)
        #expect(FileExplorerStore.classifyGitState(for: change) == .deleted)
    }

    @Test func classifyGitState_untracked_mapsToAdded() {
        // "??" from git status (untracked section) maps to .added in the UI
        let change = GitFileChange(path: "src/new.swift", indexStatus: "?", workTreeStatus: "?", section: .untracked)
        #expect(FileExplorerStore.classifyGitState(for: change) == .added)
    }

    @Test func classifyGitState_renamed() {
        let change = GitFileChange(path: "src/new.swift", indexStatus: "R", workTreeStatus: " ", section: .staged)
        #expect(FileExplorerStore.classifyGitState(for: change) == .renamed)
    }

    // MARK: - mergeGitState priority

    @Test func mergeGitState_nilExisting_returnsNew() {
        #expect(FileExplorerStore.mergeGitState(nil, .modified) == .modified)
    }

    @Test func mergeGitState_deleted_winsOver_modified() {
        // deleted has higher priority than modified
        #expect(FileExplorerStore.mergeGitState(.modified, .deleted) == .deleted)
        #expect(FileExplorerStore.mergeGitState(.deleted, .modified) == .deleted)
    }

    @Test func mergeGitState_conflicted_winsOver_deleted() {
        // conflicted has the highest priority
        #expect(FileExplorerStore.mergeGitState(.deleted, .conflicted) == .conflicted)
    }

    // MARK: - sortEntries

    @Test func sortEntries_emptyInput_returnsEmpty() {
        let result = FileExplorerStore.sortEntries([])
        #expect(result.isEmpty)
    }

    /// sortEntries must place directories before files even when the directory name
    /// sorts AFTER the file name alphabetically (z-dir > a-file.txt).
    /// Using conflicting names ensures a purely-alphabetical comparator would fail.
    @Test func sortEntries_directoriesBeforeFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("a-file.txt")  // alphabetically first
        let dirURL  = tmp.appendingPathComponent("z-dir")       // alphabetically last
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Pass file first to prove sorting, not insertion order
        let sorted = FileExplorerStore.sortEntries([fileURL, dirURL])

        // Directory must win even though "z-dir" > "a-file.txt" alphabetically
        #expect(sorted.first?.lastPathComponent == "z-dir")
        #expect(sorted.last?.lastPathComponent  == "a-file.txt")
    }

    @Test func sortEntries_alphabeticalWithinFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for name in ["c.txt", "a.txt", "b.txt"] {
            try "x".write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let urls = ["c.txt", "a.txt", "b.txt"].map { tmp.appendingPathComponent($0) }
        let sorted = FileExplorerStore.sortEntries(urls)

        #expect(sorted.map { $0.lastPathComponent } == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func sortEntries_alphabeticalWithinDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for name in ["src", "lib", "bin"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let urls = ["src", "lib", "bin"].map { tmp.appendingPathComponent($0) }
        let sorted = FileExplorerStore.sortEntries(urls)

        #expect(sorted.map { $0.lastPathComponent } == ["bin", "lib", "src"])
    }

    // MARK: - compactDirectoryPrefixes

    @Test func compactDirectoryPrefixes_removesRedundantChildren() {
        // /project/node_modules/foo should be subsumed by /project/node_modules
        let result = FileExplorerStore.compactDirectoryPrefixes([
            "/project/node_modules",
            "/project/node_modules/lodash",
            "/project/.build"
        ])
        #expect(result.contains("/project/node_modules"))
        #expect(result.contains("/project/.build"))
        #expect(!result.contains("/project/node_modules/lodash"))
    }

    @Test func compactDirectoryPrefixes_noOverlap_returnsAll() {
        let input = ["/a/foo", "/b/bar", "/c/baz"]
        let result = FileExplorerStore.compactDirectoryPrefixes(input)
        #expect(Set(result) == Set(input))
    }

    // MARK: - File editor session persistence

    @Test func fileEditorSessionPersistence_roundTripsPerProject() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let projectA = URL(fileURLWithPath: "/Users/openowl-project-a")
        let projectB = URL(fileURLWithPath: "/Users/openowl-project-b")
        let session = FileEditorSession(
            openFilePaths: ["/Users/openowl-project-a/a.swift", "/Users/openowl-project-a/b.swift"],
            activeFilePath: "/Users/openowl-project-a/b.swift"
        )

        FileEditorSessionPersistence.save(
            session,
            forProjectKey: FileEditorSessionPersistence.projectKey(for: projectA),
            defaults: defaults
        )

        #expect(FileEditorSessionPersistence.load(
            forProjectKey: FileEditorSessionPersistence.projectKey(for: projectA),
            defaults: defaults
        ) == FileEditorSessionPersistence.normalize(session))
        #expect(FileEditorSessionPersistence.load(
            forProjectKey: FileEditorSessionPersistence.projectKey(for: projectB),
            defaults: defaults
        ) == nil)
    }

    @Test func fileEditorSessionPersistence_emptySessionClearsProject() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let project = URL(fileURLWithPath: "/Users/openowl-project")
        let projectKey = FileEditorSessionPersistence.projectKey(for: project)
        FileEditorSessionPersistence.save(
            FileEditorSession(openFilePaths: ["/Users/openowl-project/a.swift"], activeFilePath: nil),
            forProjectKey: projectKey,
            defaults: defaults
        )
        FileEditorSessionPersistence.save(
            FileEditorSession(openFilePaths: [], activeFilePath: nil),
            forProjectKey: projectKey,
            defaults: defaults
        )

        #expect(FileEditorSessionPersistence.load(forProjectKey: projectKey, defaults: defaults) == nil)
    }

    @Test func fileEditorSessionPersistence_normalizeDedupesAndRepairsActivePath() {
        let normalized = FileEditorSessionPersistence.normalize(
            FileEditorSession(
                openFilePaths: ["/tmp/openowl-project/a.swift", "/tmp/openowl-project/a.swift"],
                activeFilePath: "/tmp/openowl-project/missing.swift"
            )
        )

        #expect(normalized.openFilePaths == [
            URL(fileURLWithPath: "/tmp/openowl-project/a.swift").standardizedFileURL.path
        ])
        #expect(normalized.activeFilePath == URL(
            fileURLWithPath: "/tmp/openowl-project/a.swift"
        ).standardizedFileURL.path)
    }

    private var defaultsSuiteName: String {
        "openowl.file-editor-session.tests"
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
