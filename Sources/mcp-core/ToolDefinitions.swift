import Foundation
import MCP
import core

public let mcpTools: [Tool] = [
    .init(
        name: "memorize",
        description: """
            Memorize one or more things, concepts, notes, etc. Search "prefixes" and "Tutorials" for examples and to remember how to memorize
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "label": .object([
                    "type": .string("string"),
                    "description": .string(
                        "A label is a keyword heavy summary that usually starts with a prefix. "),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("Complete detailed memory"),
                ]),
                "associations": .object([
                    "type": .string("array"),
                    "description": .string("Memory id's the new memory relates to."),
                ]),
            ]), "required": .array(["label", "content"]),
        ])),
    .init(
        name: "search",
        description:
            "Search memories by keywords and prefixes. To remember something fully use `recallFully`",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "keywords": .object([
                    "type": .string("array"),
                    "description": .string(
                        ""),
                ]),
                "range": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Pagination range as 'start:end', e.g. 0:50"
                    ),
                ]),
                "sort": .object(["type": .string("string"), "description": .string("")]),
            ]), "required": .array(["keywords"]),
        ]),
        annotations: Tool.Annotations(readOnlyHint: true)),
    .init(
        name: "recall",
        description: "Remember something by id",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids": .object(["type": .string("array"), "description": .string("")]),
                "depth": .object([
                    "type": .string("integer"),
                    "description": .string(
                        """
                        -1 = you will not remember anything associated to the memory
                        0 = direct associations only. Increase only when mapping a broad topic.
                        """),
                ]),
                "sort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "chronological, reverseChronological, relevance"),
                ]),
            ]), "required": .array(["ids"]),
        ])),
    .init(
        name: "recallFully",
        description: "Remember something fully",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids": .object(["type": .string("array"), "description": .string("")])
            ]), "required": .array(["ids"]),
        ])),
    .init(
        name: "allMemories",
        description:
            "Remember everything",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "range": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Pagination range as 'start:end', e.g. 0:50"
                    ),
                ]),
                "sortOrder": .object([
                    "type": .string("string"),
                    "description": .string(
                        "chronological, reverseChronological, relevance"),
                ]),
            ]),
        ]),
        annotations: Tool.Annotations(readOnlyHint: true)),
    .init(
        name: "adrift",
        description: "Find memories nothing else references",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "range": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Pagination range as 'start:end', e.g. 0:50"
                    ),
                ]),
                "sort": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Sort order: 'chronological', 'reverseChronological', or 'relevance'"),
                ]),
            ]),
        ]),
        annotations: Tool.Annotations(readOnlyHint: true)),
    .init(
        name: "associate",
        description: "Create associations between memories. The associations are bidirectional",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("The UUID of the memory to associate"),
                ]),
                "with": .object([
                    "type": .string("array"),
                    "description": .string("Array of UUIDs to associate with the target memory"),
                ]),
            ]), "required": .array(["id", "with"]),
        ])),
    .init(
        name: "dissociate",
        description: "Remove associations between memories",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("The UUID of the memory to dissociate"),
                ]),
                "from": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Array of UUIDs to remove associations from the target memory"),
                ]),
            ]), "required": .array(["id", "from"]),
        ])),
    .init(
        name: "forget",
        description:
            "Forget a memory. Pause before forgetting anything associated to `#dont-forget`",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids": .object(["type": .string("array"), "description": .string("")])
            ]), "required": .array(["ids"]),
        ])),
]
