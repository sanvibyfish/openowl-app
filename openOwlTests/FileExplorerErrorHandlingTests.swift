import Testing
import Foundation
import AppKit
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

    @Test func fileEditorDiskSignature_changesWhenFileChanges() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("a.swift")
        try "a".write(to: fileURL, atomically: true, encoding: .utf8)
        let first = try #require(FileEditorDiskSignatureProvider.signature(for: fileURL))

        try "ab".write(to: fileURL, atomically: true, encoding: .utf8)
        let second = try #require(FileEditorDiskSignatureProvider.signature(for: fileURL))

        #expect(first != second)
    }

    @Test func fileEditorDiskSignature_changesForSameSizeAtomicReplacement() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-signature-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("a.swift")
        let replacementURL = tmp.appendingPathComponent("replacement.swift")
        try "aa".write(to: fileURL, atomically: false, encoding: .utf8)
        let first = try #require(FileEditorDiskSignatureProvider.signature(for: fileURL))

        try "bb".write(to: replacementURL, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: replacementURL)
        let second = try #require(FileEditorDiskSignatureProvider.signature(for: fileURL))

        #expect(first.fileSize == second.fileSize)
        #expect(first.fileIdentifier != nil)
        #expect(second.fileIdentifier != nil)
        #expect(first.fileIdentifier != second.fileIdentifier)
    }

    /// An in-app save changes the disk signature just as much as an external
    /// edit does, because `write(atomically:)` replaces the inode. Anything that
    /// wants to distinguish "the user saved" from "the file changed underneath
    /// us" therefore cannot key off the signature — keying the editor's SwiftUI
    /// identity on it rebuilt the editor on every ⌘S and dropped the undo stack.
    @Test func fileEditorDiskSignature_changesForOwnAtomicSaveOfSameLengthContent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-signature-own-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("a.swift")
        try "aa".write(to: fileURL, atomically: true, encoding: .utf8)
        let beforeSave = try #require(FileEditorDiskSignatureProvider.signature(for: fileURL))

        // Same call `saveCurrentTab` / `saveAllDirtyTabs` make.
        try "bb".write(to: fileURL, atomically: true, encoding: .utf8)
        let afterSave = try #require(FileEditorDiskSignatureProvider.signature(for: fileURL))

        #expect(beforeSave.fileSize == afterSave.fileSize)
        #expect(beforeSave != afterSave)
    }

    @Test func fileEditorReloadCommitPolicy_rejectsDirtyTabAfterReadStarted() {
        let requestID = UUID()
        let generation = UUID()
        let signature = FileEditorDiskSignature(
            modifiedAt: Date(timeIntervalSince1970: 1),
            fileSize: 10,
            fileIdentifier: 1
        )
        let request = FileEditorReadRequest(
            id: requestID,
            sessionGeneration: generation,
            signature: signature
        )
        #expect(FileEditorReloadCommitPolicy.shouldCommit(
            isTabOpen: true,
            isDirty: false,
            request: request,
            currentRequestID: requestID,
            currentSessionGeneration: generation,
            currentDiskSignature: signature
        ))
        #expect(!FileEditorReloadCommitPolicy.shouldCommit(
            isTabOpen: true,
            isDirty: true,
            request: request,
            currentRequestID: requestID,
            currentSessionGeneration: generation,
            currentDiskSignature: signature
        ))
    }

    @Test func fileEditorReadCommitPolicy_newSameURLRequestSupersedesOldRequest() {
        let oldRequestID = UUID()
        let newRequestID = UUID()
        let generation = UUID()
        let signature = FileEditorDiskSignature(
            modifiedAt: Date(timeIntervalSince1970: 1),
            fileSize: 10,
            fileIdentifier: 1
        )
        let oldRequest = FileEditorReadRequest(
            id: oldRequestID,
            sessionGeneration: generation,
            signature: signature
        )

        #expect(!FileEditorReloadCommitPolicy.shouldCommit(
            isTabOpen: true,
            isDirty: false,
            request: oldRequest,
            currentRequestID: newRequestID,
            currentSessionGeneration: generation,
            currentDiskSignature: signature
        ))
    }

    @Test func fileEditorReloadCommitPolicy_rejectsChangedDiskSignature() {
        let requestID = UUID()
        let generation = UUID()
        let readSignature = FileEditorDiskSignature(
            modifiedAt: Date(timeIntervalSince1970: 1),
            fileSize: 10,
            fileIdentifier: 1
        )
        let newerSignature = FileEditorDiskSignature(
            modifiedAt: Date(timeIntervalSince1970: 2),
            fileSize: 10,
            fileIdentifier: 2
        )
        let request = FileEditorReadRequest(
            id: requestID,
            sessionGeneration: generation,
            signature: readSignature
        )

        #expect(!FileEditorReloadCommitPolicy.shouldCommit(
            isTabOpen: true,
            isDirty: false,
            request: request,
            currentRequestID: requestID,
            currentSessionGeneration: generation,
            currentDiskSignature: newerSignature
        ))
        #expect(FileEditorReloadCommitPolicy.shouldRetry(
            isTabOpen: true,
            isDirty: false,
            request: request,
            currentRequestID: requestID,
            currentSessionGeneration: generation,
            currentDiskSignature: newerSignature
        ))
    }

    @Test func fileEditorReadCommitPolicy_rejectsRequestFromPreviousProjectGeneration() {
        let requestID = UUID()
        let oldGeneration = UUID()
        let signature = FileEditorDiskSignature(
            modifiedAt: Date(timeIntervalSince1970: 1),
            fileSize: 10,
            fileIdentifier: 1
        )
        let request = FileEditorReadRequest(
            id: requestID,
            sessionGeneration: oldGeneration,
            signature: signature
        )

        #expect(!FileEditorReloadCommitPolicy.shouldCommit(
            isTabOpen: true,
            isDirty: false,
            request: request,
            currentRequestID: requestID,
            currentSessionGeneration: UUID(),
            currentDiskSignature: signature
        ))
    }

    @Test func fileEditorAutomaticReadPolicy_enforcesTextAndImageCaps() {
        #expect(FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: 49,
            isImage: false,
            hugeFileThreshold: 50,
            imageMaxBytes: 25
        ))
        #expect(!FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: 50,
            isImage: false,
            hugeFileThreshold: 50,
            imageMaxBytes: 25
        ))
        #expect(FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: 25,
            isImage: true,
            hugeFileThreshold: 50,
            imageMaxBytes: 25
        ))
        #expect(!FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: 26,
            isImage: true,
            hugeFileThreshold: 50,
            imageMaxBytes: 25
        ))
    }

    @Test func fileEditorURLMutation_remapsFileAndDirectoryDescendantState() throws {
        let sourceFile = URL(fileURLWithPath: "/project/src/old.swift")
        let destinationFile = URL(fileURLWithPath: "/project/src/new.swift")
        #expect(FileEditorURLMutationPolicy.remappedURL(
            sourceFile,
            moving: sourceFile,
            to: destinationFile
        ) == destinationFile)

        let sourceDirectory = URL(fileURLWithPath: "/project/src")
        let destinationDirectory = URL(fileURLWithPath: "/project/lib")
        let child = URL(fileURLWithPath: "/project/src/features/a.swift")
        let movedChild = URL(fileURLWithPath: "/project/lib/features/a.swift")
        #expect(FileEditorURLMutationPolicy.remappedURL(
            child,
            moving: sourceDirectory,
            to: destinationDirectory
        ) == movedChild)

        let requestID = UUID()
        let remappedRequests = FileEditorURLMutationPolicy.remappingValues(
            [child: requestID],
            moving: sourceDirectory,
            to: destinationDirectory
        )
        #expect(remappedRequests[child] == nil)
        #expect(remappedRequests[movedChild] == requestID)
    }

    @Test func fileEditorURLMutation_dirtyDeleteGuardIncludesDirectoryDescendants() {
        let dirtyChild = URL(fileURLWithPath: "/project/src/a.swift")
        let unaffected = URL(fileURLWithPath: "/project/tests/a.swift")
        let roots = [URL(fileURLWithPath: "/project/src")]
        let affected = Set([dirtyChild, unaffected]).filter {
            FileEditorURLMutationPolicy.isAffected($0, by: roots)
        }

        #expect(affected == [dirtyChild])
    }

    @Test func fileEditorURLMutation_detectsExactAndDirectoryDescendantCollisions() {
        let missingTargetTab = URL(fileURLWithPath: "/project/lib/a.swift")
        let sourceFile = URL(fileURLWithPath: "/project/src/a.swift")
        let exactMove = FileExplorerURLMove(source: sourceFile, destination: missingTargetTab)
        #expect(FileEditorURLMutationPolicy.collisionURL(
            openURLs: [sourceFile, missingTargetTab],
            applying: [exactMove]
        ) == missingTargetTab)

        let directoryMove = FileExplorerURLMove(
            source: URL(fileURLWithPath: "/project/src"),
            destination: URL(fileURLWithPath: "/project/lib")
        )
        #expect(FileEditorURLMutationPolicy.collisionURL(
            openURLs: [sourceFile, missingTargetTab],
            applying: [directoryMove]
        ) == missingTargetTab)
    }

    @Test @MainActor func renameNode_rejectedEditorMoveDoesNotTouchDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-rename-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.swift")
        let destinationURL = directory.appendingPathComponent("target.swift")
        try "buffer".write(to: sourceURL, atomically: true, encoding: .utf8)
        let node = FileExplorerNode(
            id: sourceURL.path,
            url: sourceURL,
            name: sourceURL.lastPathComponent,
            isDirectory: false,
            gitState: nil,
            children: nil
        )

        let result = FileExplorerStore().renameNode(
            node,
            to: destinationURL.lastPathComponent,
            approveMove: { _ in false }
        )

        #expect(result == nil)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test func pruningNodes_removesDeletedDirectoryDescendants() throws {
        let rootURL = URL(fileURLWithPath: "/project")
        let sourceURL = rootURL.appendingPathComponent("src")
        let childURL = sourceURL.appendingPathComponent("a.swift")
        let keepURL = rootURL.appendingPathComponent("README.md")
        let nodes = [
            FileExplorerNode(
                id: sourceURL.path,
                url: sourceURL,
                name: "src",
                isDirectory: true,
                gitState: nil,
                children: [
                    FileExplorerNode(
                        id: childURL.path,
                        url: childURL,
                        name: "a.swift",
                        isDirectory: false,
                        gitState: nil,
                        children: nil
                    )
                ]
            ),
            FileExplorerNode(
                id: keepURL.path,
                url: keepURL,
                name: "README.md",
                isDirectory: false,
                gitState: nil,
                children: nil
            )
        ]

        let pruned = FileExplorerStore.pruningNodes(nodes, deleting: [sourceURL])

        #expect(pruned.map(\.url) == [keepURL])
        #expect(FileExplorerStore.isURL(childURL, coveredByAny: [sourceURL]))
    }

    @Test @MainActor func unsavedTabNames_aggregatesEditorsIndependently() {
        let store = FileExplorerStore()
        let editorA = UUID()
        let editorB = UUID()

        store.publishUnsavedTabNames(["b.swift"], for: editorA)
        store.publishUnsavedTabNames(["a.swift"], for: editorB)
        #expect(store.unsavedTabNames == ["a.swift", "b.swift"])

        store.removeUnsavedTabNames(for: editorA)
        #expect(store.unsavedTabNames == ["a.swift"])

        store.publishUnsavedTabNames([], for: editorB)
        #expect(store.unsavedTabNames.isEmpty)
    }

    @Test @MainActor func switchingToUncachedProjectClearsPreviousQuickOpenFiles() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-file-switch-\(UUID().uuidString)", isDirectory: true)
        let firstProjectURL = baseURL.appendingPathComponent("first", isDirectory: true)
        let secondProjectURL = baseURL.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProjectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProjectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        try "old project\n".write(
            to: firstProjectURL.appendingPathComponent("old-project.swift"),
            atomically: true,
            encoding: .utf8
        )

        let store = FileExplorerStore()
        store.setProject(firstProjectURL)
        for _ in 0..<100 where store.quickOpenMatches.isEmpty {
            store.updateQuickOpenResults()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.quickOpenMatches.map(\.node.name) == ["old-project.swift"])

        store.setProject(secondProjectURL)
        store.updateQuickOpenResults()

        #expect(store.quickOpenMatches.isEmpty)
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
