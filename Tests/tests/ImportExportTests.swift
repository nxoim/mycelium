import Foundation
import Testing

@testable import core

@Suite
struct ImportExportTests {

    @Test("JSON import/export roundtrip")
    func test_export_import_json_roundtrip() async throws {
        let db1 = TempDirectory()
        let db2 = TempDirectory()
        var uuids: [String] = []

        for label in ["RoundA", "RoundB", "RoundC"] {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, "Round content for \(label)",
                CLIArg.db, db1.path,
            ])
            uuids.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = ProcessHelper.run([
            "associate", uuids[0], CLIArg.assocWith, uuids[1], CLIArg.db, db1.path,
        ])
        _ = ProcessHelper.run([
            "associate", uuids[2], CLIArg.assocWith, uuids[0], CLIArg.db, db1.path,
        ])

        let exportResult = ProcessHelper.run([
            "export-memory", CLIArg.jsonFlag, CLIArg.db, db1.path,
        ])
        #expect(exportResult.exitCode == 0)
        #expect(!exportResult.stdout.isEmpty)
        let exportedJSON = exportResult.stdout

        let importResult = ProcessHelper.run([
            "import-memory", CLIArg.jsonFlag, exportedJSON, CLIArg.db, db2.path,
        ])
        #expect(importResult.exitCode == 0)
        #expect(importResult.stdout.contains(OutputPattern.ok))
        #expect(importResult.stdout.contains(OutputPattern.imported))
        #expect(importResult.stdout.contains(OutputPattern.remappedIDs))
        #expect(importResult.stdout.contains(OutputPattern.arrow))

        let allMemories = ProcessHelper.run([
            "all-memories", CLIArg.db, db2.path,
        ])
        #expect(allMemories.exitCode == 0)
        #expect(allMemories.stdout.contains(OutputPattern.found + " 3 memory(s)"))

        let freshUUIDs = TestResult.allUUIDs(from: allMemories)
        #expect(freshUUIDs.count >= 3)

        for freshUUID in freshUUIDs {
            let recall = ProcessHelper.run([
                "recall", freshUUID, CLIArg.depth, "0", CLIArg.db, db2.path,
            ])
            if recall.stdout.contains("RoundC") {
                break
            }
        }
    }

    @Test("File-based import/export roundtrip")
    func test_export_import_file_roundtrip() async throws {
        let db1 = TempDirectory()
        let db2 = TempDirectory()
        let exportFile = "/tmp/mycelium-e2e-export-\(UUID().uuidString).json"

        for label in ["FileA", "FileB"] {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, "File content \(label)",
                CLIArg.db, db1.path,
            ])
            #expect(result.exitCode == 0)
        }

        let exportResult = ProcessHelper.run([
            "export-memory", CLIArg.fileFlag, exportFile, CLIArg.db, db1.path,
        ])
        #expect(exportResult.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: exportFile))

        let importResult = ProcessHelper.run([
            "import-memory", CLIArg.fileFlag, exportFile, CLIArg.db, db2.path,
        ])
        #expect(importResult.exitCode == 0)
        #expect(importResult.stdout.contains(OutputPattern.ok))
        #expect(importResult.stdout.contains(OutputPattern.imported))
        #expect(importResult.stdout.contains(OutputPattern.remappedIDs))
        #expect(importResult.stdout.contains(OutputPattern.arrow))

        let allMemories = ProcessHelper.run([
            "all-memories", CLIArg.db, db2.path,
        ])
        #expect(allMemories.exitCode == 0)
        #expect(allMemories.stdout.contains(OutputPattern.found + " 2 memory(s)"))

        try? FileManager.default.removeItem(atPath: exportFile)
    }
}
