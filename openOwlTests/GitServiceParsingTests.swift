import Testing
import Foundation
@testable import openOwl

@Suite("GitService Parsing")
struct GitServiceParsingTests {

    private let service = GitService(workingDirectory: URL(fileURLWithPath: "/tmp"))

    // MARK: - parseBranch

    @Test func parseBranch_simple() {
        let result = service.parseBranch(from: "## main")
        #expect(result.branch == "main")
        #expect(result.upstreamBranch == nil)
        #expect(result.trackingSummary == nil)
    }

    @Test func parseBranch_withUpstream() {
        let result = service.parseBranch(from: "## main...origin/main")
        #expect(result.branch == "main")
        #expect(result.upstreamBranch == "origin/main")
        #expect(result.trackingSummary == nil)
    }

    @Test func parseBranch_aheadBehind() {
        let result = service.parseBranch(from: "## feature...origin/feature [ahead 3, behind 1]")
        #expect(result.branch == "feature")
        #expect(result.upstreamBranch == "origin/feature")
        #expect(result.trackingSummary == "ahead 3, behind 1")
    }

    @Test func parseBranch_detachedHEAD() {
        let result = service.parseBranch(from: "## HEAD (no branch)")
        #expect(result.branch == "HEAD (no branch)")
        #expect(result.upstreamBranch == nil)
    }

    @Test func parseBranch_unbornBranch() {
        let result = service.parseBranch(from: "## No commits yet on trunk")
        #expect(result.branch == "trunk")
        #expect(result.upstreamBranch == nil)
        #expect(result.trackingSummary == nil)
    }

    // MARK: - parseAheadBehind

    @Test func parseAheadBehind_aheadOnly() {
        let result = service.parseAheadBehind(from: "ahead 5")
        #expect(result.ahead == 5)
        #expect(result.behind == 0)
    }

    @Test func parseAheadBehind_behindOnly() {
        let result = service.parseAheadBehind(from: "behind 2")
        #expect(result.ahead == 0)
        #expect(result.behind == 2)
    }

    @Test func parseAheadBehind_both() {
        let result = service.parseAheadBehind(from: "ahead 3, behind 1")
        #expect(result.ahead == 3)
        #expect(result.behind == 1)
    }

    @Test func parseAheadBehind_nil() {
        let result = service.parseAheadBehind(from: nil)
        #expect(result.ahead == 0)
        #expect(result.behind == 0)
    }

    // MARK: - parseStatus

    @Test func parseStatus_mixedChanges() throws {
        let output = """
        ## main...origin/main [ahead 1]
        M  file1.swift
         M file2.swift
        ?? newfile.txt
        """
        let snapshot = try service.parseStatus(output)
        #expect(snapshot.branch == "main")
        #expect(snapshot.aheadCount == 1)
        #expect(snapshot.staged.count == 1)
        #expect(snapshot.modified.count == 1)
        #expect(snapshot.untracked.count == 1)
        #expect(snapshot.staged.first?.path == "file1.swift")
        #expect(snapshot.untracked.first?.path == "newfile.txt")
    }

    @Test func parseStatus_empty() throws {
        let output = "## main"
        let snapshot = try service.parseStatus(output)
        #expect(snapshot.branch == "main")
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.modified.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    @Test func parseStatus_renamedFile() throws {
        let output = """
        ## main
        R  old.swift -> new.swift
        """
        let snapshot = try service.parseStatus(output)
        #expect(snapshot.staged.count == 1)
        #expect(snapshot.staged.first?.path == "new.swift")
    }

    // MARK: - decodePath

    @Test func decodePath_plain() {
        #expect(service.decodePath("src/file.swift") == "src/file.swift")
    }

    @Test func decodePath_quoted() {
        #expect(service.decodePath("\"src/file name.swift\"") == "src/file name.swift")
    }

    @Test func decodePath_escaped() {
        #expect(service.decodePath("\"path\\\\to\\\"file\"") == "path\\to\"file")
    }

    @Test func decodePath_octalSingleByte() {
        // \101 = 'A' (octal 101 = decimal 65)
        #expect(service.decodePath("\"\\101.swift\"") == "A.swift")
    }

    @Test func decodePath_octalUTF8_chinese() {
        // "中" = UTF-8 bytes E4 B8 AD = octal 344 270 255
        let input = "\"\\344\\270\\255.swift\""
        #expect(service.decodePath(input) == "中.swift")
    }

    @Test func decodePath_octalMixed() {
        // Mix of ASCII and octal-encoded characters
        let input = "\"src/\\346\\226\\207\\344\\273\\266.swift\""
        #expect(service.decodePath(input) == "src/文件.swift")
    }

    // MARK: - parsePath

    @Test func parsePath_withArrow() {
        #expect(service.parsePath("old.swift -> new.swift") == "new.swift")
    }

    @Test func parsePath_withoutArrow() {
        #expect(service.parsePath("file.swift") == "file.swift")
    }
}
