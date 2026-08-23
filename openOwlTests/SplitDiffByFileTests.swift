import Testing
@testable import openOwl

@Suite("splitDiffByFile")
struct SplitDiffByFileTests {

    @Test func singleFile_modified() {
        let diff = """
        diff --git a/src/main.swift b/src/main.swift
        index abc..def 100644
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -1,3 +1,4 @@
         line1
        +added
         line2
        """
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].path == "src/main.swift")
        #expect(sections[0].status == .modified)
        #expect(sections[0].diff.contains("+added"))
    }

    @Test func multipleFiles() {
        let diff = """
        diff --git a/file1.swift b/file1.swift
        --- a/file1.swift
        +++ b/file1.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/file2.swift b/file2.swift
        --- a/file2.swift
        +++ b/file2.swift
        @@ -1 +1 @@
        -foo
        +bar
        """
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 2)
        #expect(sections[0].path == "file1.swift")
        #expect(sections[1].path == "file2.swift")
    }

    @Test func newFile_statusA() {
        let diff = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].status == .added)
        #expect(sections[0].path == "new.swift")
    }

    @Test func deletedFile_statusD() {
        let diff = """
        diff --git a/old.swift b/old.swift
        deleted file mode 100644
        --- a/old.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -line1
        -line2
        """
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].status == .deleted)
    }

    @Test func renamedFile_statusR() {
        let diff = """
        diff --git a/old.swift b/new.swift
        similarity index 95%
        rename from old.swift
        rename to new.swift
        --- a/old.swift
        +++ b/new.swift
        @@ -1 +1 @@
        -old
        +new
        """
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].status == .renamed)
    }

    @Test func emptyDiff_noSections() {
        let sections = splitDiffByFile("")
        #expect(sections.isEmpty)
    }

    @Test func mixedStatuses() {
        let diff = """
        diff --git a/added.swift b/added.swift
        new file mode 100644
        --- /dev/null
        +++ b/added.swift
        @@ -0,0 +1 @@
        +hello
        diff --git a/modified.swift b/modified.swift
        --- a/modified.swift
        +++ b/modified.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/deleted.swift b/deleted.swift
        deleted file mode 100644
        --- a/deleted.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 3)
        #expect(sections[0].status == .added)
        #expect(sections[1].status == .modified)
        #expect(sections[2].status == .deleted)
    }

    @Test func diffContent_excludesGitHeaders() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index abc..def 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1 +1 @@
        -old
        +new
        """
        let sections = splitDiffByFile(diff)
        // The diff content should NOT contain the "diff --git" line
        #expect(!sections[0].diff.contains("diff --git"))
    }

    @Test func pathWithSpaces_parsedCorrectly() {
        let diff = "diff --git a/path with spaces/file.swift b/path with spaces/file.swift\n--- a/path with spaces/file.swift\n+++ b/path with spaces/file.swift\n@@ -1 +1 @@\n-old\n+new"
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].path == "path with spaces/file.swift")
    }

    @Test func quotedNonASCIIPath_parsedCorrectly() {
        let diff = #"""
diff --git "a/\344\270\255\346\226\207.swift" "b/\344\270\255\346\226\207.swift"
--- "a/\344\270\255\346\226\207.swift"
+++ "b/\344\270\255\346\226\207.swift"
@@ -1 +1 @@
-old
+new
"""#
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].path == "中文.swift")
    }

    @Test func binaryFile_diffContent() {
        let diff = "diff --git a/image.png b/image.png\nindex abc..def 100644\nBinary files a/image.png and b/image.png differ"
        let sections = splitDiffByFile(diff)
        #expect(sections.count == 1)
        #expect(sections[0].path == "image.png")
        #expect(sections[0].diff.contains("Binary files"))
    }

    @Test func renamedFile_pathIsDestination() {
        let diff = "diff --git a/old.swift b/new.swift\nsimilarity index 95%\nrename from old.swift\nrename to new.swift\n--- a/old.swift\n+++ b/new.swift\n@@ -1 +1 @@\n-old\n+new"
        let sections = splitDiffByFile(diff)
        #expect(sections[0].path == "new.swift")
        #expect(sections[0].status == .renamed)
    }
}
