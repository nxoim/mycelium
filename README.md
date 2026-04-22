# mycelium
Simple node based memory system for AI agents built in Swift. CLI, MCP (stdio and HTTP), and observation server.

## The concept
The core idea is to give LLMs a persistent, association-based memory system they can manage autonomously. Memories are presented as summaries and associated memories, for minimal impact on context window usage. The model is expected to memorize relevant information unprompted and recall it when it deems it's needed. 

For example, while debugging a problem, the model might search its memory for something adjacent to the topic at hand, then find a relevant memory, then read it fully, and then shift the direction of the conversation.

## The setup
1. Install the [Swift toolchain](https://www.swift.org/install/), if you don't already have it. Make sure it's 6.3+.

2. Build the binaries:
   ```bash
   scripts/build-and-package-release-macos-aarch64.sh
   ```
3. Copy the output binaries from `.tmp/release/` wherever you need. Prebuilt binaries are not yet published.
4. Add the mcp to your harness. You can either launch `mcp-server` to host locally, or you can use the `mcp-stdio` binary normally. 

Upon launch an sqlite memory database will be created in the folder containing the executable, unless specified otherwise via `--db`.

## How it works in practice
With newer qwen models it works... somewhat... if directed via rules/skills. For example:
```
You have persistent memory. 
Before each reply you should ask yourself whether you know anything about the topic of the conversation, or any of the details, and then you should try to recall any relevant information by keywords. 
You should memorize anything you learn with the user, and when you memorize something you should also memorize the context - the when, the how, the why of your decision to memorize.
```
A memory guide can be provided for memorization to the model to help guide its memory tool usage. See [MEMORY-GUIDE.md](MEMORY-GUIDE.md). I've found, anecdotally, that better results are achieved when, for example, memory labels are predictable by containing prefixes ("Document:", "Goal:", etc.), and when associations contain memories that act like topic tags and definitions ("Swift Programming Language", "#prefixes", etc.).
