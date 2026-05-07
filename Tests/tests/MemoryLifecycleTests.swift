import Foundation
import Testing

@testable import core

@Suite
struct MemoryLifecycleTests {

    @Test("Single memory CRUD lifecycle")
    func test_memory_lifecycle_cli() async throws {
        let db = TempDirectory()
        let memorizeResult = ProcessHelper.run([
            "memorize", "--label", "Test", "--content", "Hello world",
            "--db", db.path,
        ])
        #expect(memorizeResult.exitCode == 0)
        let uuids = memorizeResult.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
        #expect(uuids.count == 1)
        let uuid = uuids[0]
        #expect(UUID(uuidString: uuid) != nil)

        let recallResult = ProcessHelper.run(["recall", uuid, "--depth", "1", "--db", db.path])
        #expect(recallResult.exitCode == 0)
        // Tree format: root with "## Associated with nothing" when no associations
        #expect(recallResult.stdout.contains("Test"))
        #expect(recallResult.stdout.contains("Associated with nothing"))

        let recallFullyResult = ProcessHelper.run(
            ["recall-fully", uuid, "--db", db.path])
        #expect(recallFullyResult.exitCode == 0)
        #expect(recallFullyResult.stdout.contains("Hello world"))

        let memorizeResult2 = ProcessHelper.run([
            "memorize", "--label", "Test2", "--content", "Second memory",
            "--db", db.path,
        ])
        #expect(memorizeResult2.exitCode == 0)
        let uuid2 = memorizeResult2.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!uuid2.isEmpty)

        let assocResult = ProcessHelper.run([
            "associate", uuid, "--with", uuid2, "--db", db.path,
        ])
        #expect(assocResult.exitCode == 0)
        #expect(assocResult.stdout.contains("OK"))
        // After association: recall should show tree format with - **Label** (id: UUID)
        let recallAfterAssoc = ProcessHelper.run(["recall", uuid, "--depth", "1", "--db", db.path])
        #expect(recallAfterAssoc.exitCode == 0)
        #expect(recallAfterAssoc.stdout.contains("Test"))
        #expect(recallAfterAssoc.stdout.contains("- **Test2**"))
        #expect(recallAfterAssoc.stdout.contains("id:"))
        // Children with no associations should NOT show "Associated with nothing" — only roots should
        #expect(
            recallAfterAssoc.stdout.contains("Associated with nothing") == false,
            "Children should not show 'Associated with nothing' — only roots should")
    }

    @Test("Batch memorize and recall")
    func test_batch_memorize_and_recall() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        for i in 0..<3 {
            let result = ProcessHelper.run([
                "memorize", "--label", "BatchItem\(i)", "--content", "Content \(i)",
                "--db", db.path,
            ])
            #expect(result.exitCode == 0)
            let u = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!u.isEmpty)
            uuids.append(u)
        }

        // Batch recall: tree format with - **Label** (id: UUID) for associations
        let recallResult = ProcessHelper.run([
            "recall", uuids[0], uuids[1], uuids[2], "--db", db.path,
        ])
        #expect(recallResult.exitCode == 0)
        #expect(recallResult.stdout.contains("BatchItem0"))
        #expect(recallResult.stdout.contains("BatchItem1"))
        #expect(recallResult.stdout.contains("BatchItem2"))

        let recallFullyResult = ProcessHelper.run([
            "recall-fully", uuids[0], uuids[1], uuids[2], "--db", db.path,
        ])
        #expect(recallFullyResult.exitCode == 0)
        #expect(recallFullyResult.stdout.contains("Content 0"))
        #expect(recallFullyResult.stdout.contains("Content 1"))
        #expect(recallFullyResult.stdout.contains("Content 2"))
    }

    @Test("Forget cascade behavior")
    func test_forget_cascade() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        let resultA = ProcessHelper.run([
            "memorize", "--label", "Alpha", "--content", "Memory A", "--db", db.path,
        ])
        uuids.append(resultA.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let resultB = ProcessHelper.run([
            "memorize", "--label", "Beta", "--content", "Memory B", "--db", db.path,
        ])
        uuids.append(resultB.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let assocResult = ProcessHelper.run([
            "associate", uuids[1], "--with", uuids[0], "--db", db.path,
        ])
        #expect(assocResult.exitCode == 0)
        #expect(assocResult.stdout.contains("OK"))

        let forgetResult = ProcessHelper.run([
            "forget", uuids[0], "--db", db.path,
        ])
        #expect(forgetResult.exitCode == 0)

        let recallResult = ProcessHelper.run([
            "recall", uuids[1], "--depth", "0", "--db", db.path,
        ])
        #expect(recallResult.exitCode == 0)
        // After cascade forget: root with "## Associated with nothing"
        #expect(
            recallResult.stdout.contains("Associated with nothing"))

        // C4: forget --ids error reporting — should report which IDs failed
        let fakeUUID = UUID().uuidString
        let forgetFailedResult = ProcessHelper.run([
            "forget", fakeUUID, "--db", db.path,
        ])
        // C4: Expected: output should contain the specific failed UUID
        // Currently NOT implemented — only generic message is shown
        #expect(forgetFailedResult.exitCode != 0)
        #expect(
            forgetFailedResult.stderr.contains(fakeUUID)
                || forgetFailedResult.stdout.contains(fakeUUID),
            "C4: forget should report which IDs failed — expected output to contain '\(fakeUUID)'")
    }

    @Test("Nonexistent recall returns null")
    func test_nonexistent_recall_returns_null() async throws {
        let db = TempDirectory()
        let fakeUUID = "00000000-0000-0000-0000-000000000000"

        let recallResult = ProcessHelper.run([
            "recall", fakeUUID, "--depth", "0", "--db", db.path,
        ])
        #expect(recallResult.exitCode == 0)
        #expect(recallResult.stdout.contains("null"))

        let recallFullyResult = ProcessHelper.run([
            "recall-fully", fakeUUID, "--db", db.path,
        ])
        #expect(recallFullyResult.exitCode == 0)
        #expect(recallFullyResult.stdout.contains("null"))
    }

    @Test("Recall depth expansion")
    func test_recall_depth_expansion() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        for label in ["DeepD", "DeepC", "DeepB", "DeepA"] {
            let result = ProcessHelper.run([
                "memorize", "--label", label, "--content", "Content for \(label)",
                "--db", db.path,
            ])
            uuids.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = ProcessHelper.run([
            "associate", uuids[0], "--with", uuids[1], "--db", db.path,
        ])
        _ = ProcessHelper.run([
            "associate", uuids[1], "--with", uuids[2], "--db", db.path,
        ])
        _ = ProcessHelper.run([
            "associate", uuids[2], "--with", uuids[3], "--db", db.path,
        ])

        // Depth 0: root node with no associations should show "## Associated with nothing"
        let depth0 = ProcessHelper.run([
            "recall", uuids[0], "--depth", "0", "--db", db.path,
        ])
        #expect(depth0.exitCode == 0)
        #expect(depth0.stdout.contains("# DeepD"))
        #expect(!depth0.stdout.contains("# DeepC"))

        // Depth 1: tree format with - markers, all labels + id expanded
        let depth1 = ProcessHelper.run([
            "recall", uuids[0], "--depth", "1", "--db", db.path,
        ])
        #expect(depth1.exitCode == 0)
        #expect(depth1.stdout.contains("# DeepD"))
        #expect(depth1.stdout.contains("- **DeepC**"))
        #expect(depth1.stdout.contains("id:"))
        #expect(!depth1.stdout.contains("# DeepB"))

        // Depth 2: tree format with - markers, all labels + id expanded
        let depth2 = ProcessHelper.run([
            "recall", uuids[0], "--depth", "2", "--db", db.path,
        ])
        #expect(depth2.exitCode == 0)
        #expect(depth2.stdout.contains("# DeepD"))
        #expect(depth2.stdout.contains("- **DeepC**"))
        #expect(depth2.stdout.contains("-- **DeepB**"))
        #expect(depth2.stdout.contains("id:"))
        #expect(depth2.stdout.contains("--- **DeepA**"))

        let depthNeg = ProcessHelper.run([
            "recall", uuids[0], "--depth", "0", "--db", db.path,
        ])
        #expect(depthNeg.exitCode == 0)
        #expect(depthNeg.stdout.contains("# DeepD"))
        #expect(!depthNeg.stdout.contains("# DeepC"))
    }

    @Test("Empty label validation")
    func test_empty_label_validation() async throws {
        let db = TempDirectory()

        // Empty label should throw an error
        let emptyLabelResult = ProcessHelper.run([
            "memorize", "--label", "", "--content", "Should fail",
            "--db", db.path,
        ])
        #expect(emptyLabelResult.exitCode != 0)

        // A5: Error message should contain structured info (not just generic)
        #expect(
            emptyLabelResult.stderr.contains("empty") || emptyLabelResult.stderr.contains("Empty")
                || emptyLabelResult.stderr.contains("label")
                || emptyLabelResult.stderr.contains("Label"),
            "A5: Error should mention 'empty' or 'label', got: \(emptyLabelResult.stderr)")

        // Whitespace-only label should also throw an error
        let whitespaceLabelResult = ProcessHelper.run([
            "memorize", "--label", "   ", "--content", "Should also fail",
            "--db", db.path,
        ])
        #expect(whitespaceLabelResult.exitCode != 0)

        // A5: Whitespace error should also mention whitespace
        #expect(
            whitespaceLabelResult.stderr.contains("whitespace")
                || whitespaceLabelResult.stderr.contains("Whitespace")
                || whitespaceLabelResult.stderr.contains("empty")
                || whitespaceLabelResult.stderr.contains("Empty"),
            "A5: Whitespace error should mention 'whitespace' or 'empty', got: \(whitespaceLabelResult.stderr)"
        )

        // Tab/newline-only label should also throw an error
        let tabLabelResult = ProcessHelper.run([
            "memorize", "--label", "\t\n", "--content", "Should also fail",
            "--db", db.path,
        ])
        #expect(tabLabelResult.exitCode != 0)
    }
}
