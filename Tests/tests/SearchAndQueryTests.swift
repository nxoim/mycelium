import Foundation
import Testing

@testable import core

@Suite
struct SearchAndQueryTests {

    @Test("Search keyword union")
    func test_search_keyword_union() async throws {
        let db = TempDirectory()

        let memories: [(label: String, content: String)] = [
            ("SwiftProgramming", "Swift is a language"),
            ("KotlinProgramming", "Kotlin is a language"),
            ("GeneralComputing", "Swift and Kotlin are languages"),
        ]
        for (label, content) in memories {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, content,
                CLIArg.db, db.path,
            ])
            #expect(result.exitCode == 0)
        }

        let searchResult = ProcessHelper.run([
            "search", "Swift", "Kotlin", CLIArg.db, db.path,
        ])
        #expect(searchResult.exitCode == 0)
        #expect(searchResult.stdout.contains("## Found 3 memory(s)"))
        #expect(searchResult.stdout.contains("SwiftProgramming"))
        #expect(searchResult.stdout.contains("KotlinProgramming"))
        #expect(searchResult.stdout.contains("GeneralComputing"))

        let noResult = ProcessHelper.run([
            "search", "nonexistent_xyz_12345", CLIArg.db, db.path,
        ])
        #expect(noResult.exitCode == 0)
        #expect(noResult.stdout.contains("## Found 0 memory(s)"))
    }

    @Test("Search relevance ranking")
    func test_search_relevance_ranking() async throws {
        let db = TempDirectory()

        let _ = ProcessHelper.run([
            "memorize", CLIArg.label, "SwiftProgramming", CLIArg.content, "nothing here",
            CLIArg.db, db.path,
        ])
        let _ = ProcessHelper.run([
            "memorize", CLIArg.label, "AboutSwift", CLIArg.content, "Swift is a language",
            CLIArg.db, db.path,
        ])
        let _ = ProcessHelper.run([
            "memorize", CLIArg.label, "General", CLIArg.content, "Swift and Kotlin are languages",
            CLIArg.db, db.path,
        ])

        let searchResult = ProcessHelper.run([
            "search", "Swift", CLIArg.sort, "relevance", CLIArg.db, db.path,
        ])
        #expect(searchResult.exitCode == 0)
        #expect(searchResult.stdout.contains(OutputPattern.found + " 3 memory(s)"))
        #expect(searchResult.stdout.contains("SwiftProgramming"))
        #expect(searchResult.stdout.contains("AboutSwift"))
        #expect(searchResult.stdout.contains("General"))
    }

    @Test("All memories pagination and sort")
    func test_all_memories_pagination_and_sort() async throws {
        let db = TempDirectory()

        for i in 0..<5 {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, "Mem\(i)", CLIArg.content, "Content \(i)",
                CLIArg.db, db.path,
            ])
            #expect(result.exitCode == 0)
        }

        let range1 = ProcessHelper.run([
            "all-memories", CLIArg.range, "0:3", CLIArg.db, db.path,
        ])
        #expect(range1.exitCode == 0)
        #expect(range1.stdout.contains(OutputPattern.found + " 3 memory(s)"))

        let range2 = ProcessHelper.run([
            "all-memories", CLIArg.range, "3:5", CLIArg.db, db.path,
        ])
        #expect(range2.exitCode == 0)
        #expect(range2.stdout.contains(OutputPattern.found + " 2 memory(s)"))

        let chron = ProcessHelper.run([
            "all-memories", CLIArg.sort, "chronological", CLIArg.db, db.path,
        ])
        #expect(chron.exitCode == 0)
        #expect(chron.stdout.contains("Mem0"))

        let reverse = ProcessHelper.run([
            "all-memories", CLIArg.sort, "reverseChronological", CLIArg.db, db.path,
        ])
        #expect(reverse.exitCode == 0)
        #expect(reverse.stdout.contains("Mem4"))
    }

    @Test("Adrift orphan detection")
    func test_adrift_orphan_detection() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        let resultA = ProcessHelper.run([
            "memorize", CLIArg.label, "OrphanA", CLIArg.content, "I am alone",
            CLIArg.db, db.path,
        ])
        uuids.append(resultA.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let resultB = ProcessHelper.run([
            "memorize", CLIArg.label, "ReferencedB", CLIArg.content, "I have a link",
            CLIArg.db, db.path,
        ])
        uuids.append(resultB.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        _ = ProcessHelper.run([
            "memorize", CLIArg.label, "TrueOrphan", CLIArg.content, "I am truly alone",
            CLIArg.db, db.path,
        ])

        _ = ProcessHelper.run([
            "associate", uuids[1], CLIArg.assocWith, uuids[0], CLIArg.db, db.path,
        ])

        let adriftResult = ProcessHelper.run(["adrift", CLIArg.db, db.path])
        #expect(adriftResult.exitCode == 0)
        #expect(adriftResult.stdout.contains(OutputPattern.found))
        #expect(adriftResult.stdout.contains("TrueOrphan"))
        #expect(adriftResult.stdout.contains(OutputPattern.associatedWithNothing))
    }

    @Test("Adrift with depth parameter")
    func test_adrift_with_depth() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        let resultA = ProcessHelper.run([
            "memorize", CLIArg.label, "OrphanDeepA", CLIArg.content, "I am alone",
            CLIArg.db, db.path,
        ])
        uuids.append(resultA.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let resultB = ProcessHelper.run([
            "memorize", CLIArg.label, "OrphanDeepB", CLIArg.content, "I am also alone",
            CLIArg.db, db.path,
        ])
        uuids.append(resultB.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let adriftDefault = ProcessHelper.run(["adrift", CLIArg.db, db.path])
        #expect(adriftDefault.exitCode == 0)
        #expect(adriftDefault.stdout.contains(OutputPattern.found + " 2 memory(s)"))
        #expect(adriftDefault.stdout.contains("OrphanDeepA"))
        #expect(adriftDefault.stdout.contains("OrphanDeepB"))
        #expect(adriftDefault.stdout.contains(OutputPattern.associatedWithNothing))

        let adriftDepth0 = ProcessHelper.run([
            "adrift", CLIArg.depth, "0", CLIArg.db, db.path,
        ])
        #expect(adriftDepth0.exitCode == 0)
        #expect(adriftDepth0.stdout.contains(OutputPattern.found + " 2 memory(s)"))
        #expect(adriftDepth0.stdout.contains("OrphanDeepA"))
        #expect(adriftDepth0.stdout.contains("OrphanDeepB"))
        #expect(adriftDepth0.stdout.contains(OutputPattern.associatedWithNothing))

        let adriftDepth1 = ProcessHelper.run([
            "adrift", CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(adriftDepth1.exitCode == 0)
        #expect(adriftDepth1.stdout.contains(OutputPattern.found + " 2 memory(s)"))
        #expect(adriftDepth1.stdout.contains("OrphanDeepA"))
        #expect(adriftDepth1.stdout.contains("OrphanDeepB"))
        #expect(adriftDepth1.stdout.contains(OutputPattern.associatedWithNothing))

        let adriftDepthAlias = ProcessHelper.run([
            "adrift", CLIArg.depth, CLIArg.Depth.noAssociations.rawValue, CLIArg.db, db.path,
        ])
        #expect(adriftDepthAlias.exitCode == 0)
        #expect(adriftDepthAlias.stdout.contains(OutputPattern.found + " 2 memory(s)"))
        #expect(adriftDepthAlias.stdout.contains("OrphanDeepA"))
        #expect(adriftDepthAlias.stdout.contains("OrphanDeepB"))
        #expect(adriftDepthAlias.stdout.contains(OutputPattern.associatedWithNothing))
    }

    @Test("Search with depth parameter")
    func test_search_with_depth() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        for label in ["SearchRoot", "SearchChild", "SearchGrandchild"] {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, "Content for \(label)",
                CLIArg.db, db.path,
            ])
            uuids.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = ProcessHelper.run([
            "associate", uuids[0], CLIArg.assocWith, uuids[1], CLIArg.db, db.path,
        ])
        _ = ProcessHelper.run([
            "associate", uuids[1], CLIArg.assocWith, uuids[2], CLIArg.db, db.path,
        ])

        let searchDepth0 = ProcessHelper.run([
            "search", "SearchRoot", CLIArg.depth, "0", CLIArg.db, db.path,
        ])
        #expect(searchDepth0.exitCode == 0)
        #expect(searchDepth0.stdout.contains(OutputPattern.found + " 1 memory(s)"))
        #expect(searchDepth0.stdout.contains("SearchRoot"))
        #expect(searchDepth0.stdout.contains("- **SearchChild**"))

        let searchDepth1 = ProcessHelper.run([
            "search", "SearchRoot", CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(searchDepth1.exitCode == 0)
        #expect(searchDepth1.stdout.contains(OutputPattern.found + " 1 memory(s)"))
        #expect(searchDepth1.stdout.contains("SearchRoot"))
        #expect(searchDepth1.stdout.contains("- **SearchChild**"))
        #expect(searchDepth1.stdout.contains("id:"))

        let searchDepthNeg = ProcessHelper.run([
            "search", "SearchRoot", CLIArg.depth, CLIArg.Depth.all.rawValue, CLIArg.db, db.path,
        ])
        #expect(searchDepthNeg.exitCode == 0)
        #expect(searchDepthNeg.stdout.contains(OutputPattern.found + " 1 memory(s)"))
        #expect(searchDepthNeg.stdout.contains("SearchRoot"))
        #expect(searchDepthNeg.stdout.contains("- **SearchChild**"))
        #expect(searchDepthNeg.stdout.contains("id:"))

        // Diamond pattern duplicate test — create A→B, A→C, B→D, C→D
        let diamondRoot = ProcessHelper.run([
            "memorize", CLIArg.label, "DiamondRoot", CLIArg.content, "Root",
            CLIArg.db, db.path,
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let diamondLeft = ProcessHelper.run([
            "memorize", CLIArg.label, "DiamondLeft", CLIArg.content, "Left",
            CLIArg.db, db.path,
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let diamondRight = ProcessHelper.run([
            "memorize", CLIArg.label, "DiamondRight", CLIArg.content, "Right",
            CLIArg.db, db.path,
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let diamondBottom = ProcessHelper.run([
            "memorize", CLIArg.label, "DiamondBottom", CLIArg.content, "Bottom",
            CLIArg.db, db.path,
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let diamondUUIDs = [diamondRoot, diamondLeft, diamondRight, diamondBottom]

        _ = ProcessHelper.run([
            "associate", diamondUUIDs[0], CLIArg.assocWith, diamondUUIDs[1],
            CLIArg.db, db.path,
        ])
        _ = ProcessHelper.run([
            "associate", diamondUUIDs[0], CLIArg.assocWith, diamondUUIDs[2],
            CLIArg.db, db.path,
        ])
        _ = ProcessHelper.run([
            "associate", diamondUUIDs[1], CLIArg.assocWith, diamondUUIDs[3],
            CLIArg.db, db.path,
        ])
        _ = ProcessHelper.run([
            "associate", diamondUUIDs[2], CLIArg.assocWith, diamondUUIDs[3],
            CLIArg.db, db.path,
        ])

        let diamondRecall = ProcessHelper.run([
            "recall", diamondUUIDs[0], CLIArg.depth, "2", CLIArg.db, db.path,
        ])
        #expect(diamondRecall.exitCode == 0)

        let allUUIDsInOutput = TestResult.allUUIDs(from: diamondRecall)
        let uniqueUUIDs = Set(allUUIDsInOutput)
        #expect(
            allUUIDsInOutput.count == uniqueUUIDs.count,
            "No duplicate nodes in recall output. Total: \(allUUIDsInOutput.count), Unique: \(uniqueUUIDs.count)"
        )

        let searchDepthAlias = ProcessHelper.run([
            "search", "SearchRoot", CLIArg.depth, CLIArg.Depth.noAssociations.rawValue,
            CLIArg.db, db.path,
        ])
        #expect(searchDepthAlias.exitCode == 0)
        #expect(
            searchDepthAlias.stdout == searchDepthNeg.stdout,
            "--depth no-associations should produce same output as --depth=-1")
    }

    @Test("All memories with depth parameter")
    func test_all_memories_with_depth() async throws {
        let db = TempDirectory()
        var uuids: [String] = []

        for label in ["AllMemA", "AllMemB", "AllMemC"] {
            let result = ProcessHelper.run([
                "memorize", CLIArg.label, label, CLIArg.content, "Content for \(label)",
                CLIArg.db, db.path,
            ])
            uuids.append(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = ProcessHelper.run([
            "associate", uuids[0], CLIArg.assocWith, uuids[1], CLIArg.db, db.path,
        ])
        _ = ProcessHelper.run([
            "associate", uuids[1], CLIArg.assocWith, uuids[2], CLIArg.db, db.path,
        ])

        let allMemDefault = ProcessHelper.run([
            "all-memories", CLIArg.db, db.path,
        ])
        #expect(allMemDefault.exitCode == 0)
        #expect(allMemDefault.stdout.contains(OutputPattern.found + " 3 memory(s)"))
        #expect(allMemDefault.stdout.contains("AllMemA"))
        #expect(allMemDefault.stdout.contains("- **AllMemB**"))

        let allMemDepth1 = ProcessHelper.run([
            "all-memories", CLIArg.depth, "1", CLIArg.db, db.path,
        ])
        #expect(allMemDepth1.exitCode == 0)
        #expect(allMemDepth1.stdout.contains(OutputPattern.found + " 3 memory(s)"))
        #expect(allMemDepth1.stdout.contains("AllMemA"))
        #expect(allMemDepth1.stdout.contains("- **AllMemB**"))
        #expect(allMemDepth1.stdout.contains("id:"))

        let allMemDepthNeg = ProcessHelper.run([
            "all-memories", CLIArg.depth, CLIArg.Depth.all.rawValue, CLIArg.db, db.path,
        ])
        #expect(allMemDepthNeg.exitCode == 0)
        #expect(allMemDepthNeg.stdout.contains(OutputPattern.found + " 3 memory(s)"))
        #expect(allMemDepthNeg.stdout.contains("AllMemA"))
        #expect(allMemDepthNeg.stdout.contains("- **AllMemB**"))
        #expect(allMemDepthNeg.stdout.contains("- **AllMemC**"))
        #expect(allMemDepthNeg.stdout.contains("id:"))
    }

    @Test("Summary node via HTTP API with depth")
    func test_summary_node_via_http_api() async throws {
        let server = TestServer(port: PortAllocator.allocate())
        try await server.start()
        defer { server.stop() }

        let uuidA = UUID()
        let uuidB = UUID()
        let uuidC = UUID()

        let memA = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)/memories")!,
            body:
                "[{\"id\":\"\(uuidA)\",\"label\":\"TreeA\",\"content\":\"Root\",\"associations\":[]}]"
        )
        #expect(memA.statusCode == 200)

        let memB = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)/memories")!,
            body:
                "[{\"id\":\"\(uuidB)\",\"label\":\"TreeB\",\"content\":\"Child\",\"associations\":[]}]"
        )
        #expect(memB.statusCode == 200)

        let memC = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)/memories")!,
            body:
                "[{\"id\":\"\(uuidC)\",\"label\":\"TreeC\",\"content\":\"Grandchild\",\"associations\":[]}]"
        )
        #expect(memC.statusCode == 200)

        _ = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)/memories/\(uuidC)/associate")!,
            body: "[\"\(uuidB)\"]"
        )
        _ = HTTPClient.postRaw(
            url: URL(string: "\(server.baseURL)/memories/\(uuidB)/associate")!,
            body: "[\"\(uuidA)\"]"
        )

        let tree = HTTPClient.get(
            url: URL(
                string: "\(server.baseURL)\(HTTPPath.nodeAssociations(uuidA.uuidString))"
            )!)
        #expect(tree.statusCode == 200)
        #expect(!tree.body.isEmpty)

        let treeJSON = tree.jsonData
        #expect(treeJSON != nil)
        if let node = treeJSON {
            #expect(node["id"] != nil)
            #expect(node["label"] as? String == "TreeA")
            #expect(node["associations"] is [[String: Any]])

            // depth field required for tree rendering
            #expect(
                node["depth"] != nil,
                "Node JSON should contain a 'depth' field. Keys: \(node.keys)")
        }
    }
}
