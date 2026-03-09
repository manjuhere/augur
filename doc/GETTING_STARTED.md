# Getting Started

This guide walks you through setting up and using the Augur MCP server.

## Prerequisites

- **Dart SDK 3.0+** — If you have Flutter installed, you already have this.
- **An MCP-compatible agent** — Claude Code, Cursor, VS Code Copilot, Windsurf, or any MCP client.

Verify your Dart SDK:

```bash
dart --version
# Should show 3.0.0 or later
```

## Installation

### Option 1: Install from pub.dev (recommended)

```bash
dart pub global activate augur
```

This installs `augur` as a globally available command. Make sure `~/.pub-cache/bin` is on your PATH:

```bash
# Add to your shell profile (~/.zshrc, ~/.bashrc, etc.) if not already there
export PATH="$PATH":"$HOME/.pub-cache/bin"
```

### Option 2: Install from source

```bash
git clone https://github.com/manjuhere/augur.git
cd augur
dart pub get
```

### Option 3: Compile to native executable

For faster startup (~50ms vs ~2s), compile to a native binary:

```bash
git clone https://github.com/manjuhere/augur.git
cd augur
dart pub get
dart compile exe bin/server.dart -o augur
```

## MCP Server Configuration

After installing via `dart pub global activate augur`, use `dart pub global run augur:server` as the command in your MCP config. This works universally because `dart` is already on your system PATH.

If you installed from source, use `"command": "dart"` with `"args": ["run", "/path/to/augur/bin/server.dart"]` instead.

### Claude Code

Run:

```bash
claude mcp add --transport stdio augur --scope user -- dart pub global run augur:server
```

This registers Augur across all your projects. To verify:

```bash
claude mcp list
```

### Cursor

Add to `.cursor/mcp.json` in your project or global Cursor settings:

```json
{
  "mcpServers": {
    "augur": {
      "command": "dart",
      "args": ["pub", "global", "run", "augur:server"]
    }
  }
}
```

### VS Code with Copilot

Add to your VS Code `settings.json`:

```json
{
  "mcpServers": {
    "augur": {
      "command": "dart",
      "args": ["pub", "global", "run", "augur:server"]
    }
  }
}
```

### OpenAI Codex

Add via CLI:

```bash
codex mcp add augur -- dart pub global run augur:server
```

Or add to `~/.codex/config.toml`:

```toml
[mcp_servers.augur]
command = "dart"
args = ["pub", "global", "run", "augur:server"]
```

### Windsurf

Follow Windsurf's MCP server configuration. The command and args are the same as above.

### With environment variables

**Claude Code** — pass env vars with `-e`:

```bash
claude mcp add --transport stdio augur --scope user -e GITHUB_TOKEN=ghp_your_token_here -e LOG_LEVEL=debug -- dart pub global run augur:server
```

**Cursor / VS Code** — add an `env` block in the JSON config:

```json
{
  "mcpServers": {
    "augur": {
      "command": "dart",
      "args": ["pub", "global", "run", "augur:server"],
      "env": {
        "GITHUB_TOKEN": "ghp_your_token_here",
        "LOG_LEVEL": "debug"
      }
    }
  }
}
```

For Codex, add an `[mcp_servers.augur.env]` table:

```toml
[mcp_servers.augur]
command = "dart"
args = ["pub", "global", "run", "augur:server"]

[mcp_servers.augur.env]
GITHUB_TOKEN = "ghp_your_token_here"
LOG_LEVEL = "debug"
```

## Setting Up a GitHub Token (Recommended)

Without a token, GitHub API limits you to 60 requests per hour. With a token, you get 5,000 per hour.

1. Go to [GitHub Settings > Developer settings > Personal access tokens > Fine-grained tokens](https://github.com/settings/tokens?type=beta)
2. Click **Generate new token**
3. Give it a name like "augur"
4. Set **Repository access** to "Public Repositories (read-only)"
5. No additional permissions are needed
6. Copy the token and add it to your MCP config's `env` block, or set it as a shell environment variable

## Usage Walkthrough

Once configured, restart your agent and start using the tools. Here are common workflows:

### 1. Scan Your Project

Start by scanning your project to see all dependencies:

> "Scan my Flutter project at /Users/me/my_flutter_app"

This parses `pubspec.yaml` and `pubspec.lock` to give you a complete dependency inventory with resolved versions, sources, and SDK constraints.

### 2. Check for Available Upgrades

See what's outdated:

> "Check for available upgrades in my project at /Users/me/my_flutter_app"

For a specific package:

> "Check if there are upgrades available for the provider package in my project"

This queries pub.dev for each dependency and reports current vs latest versions, whether it's a major/minor bump, and if the latest version has been retracted.

### 3. Analyze Upgrade Impact

Before upgrading, understand the impact:

> "Analyze the impact of upgrading provider to 7.0.0 in my project at /Users/me/my_flutter_app"

This is the most powerful tool. It:
- Fetches breaking changes from changelogs, GitHub releases, and issues
- Scans your codebase using the Dart AST analyzer to find exact usages of affected APIs
- Maps each breaking change to specific file and line locations in your code
- Calculates a risk score from 0-10
- Detects cascading dependency conflicts

**Analysis depth** controls how detailed the analysis is:

> "Analyze the impact of upgrading provider to 7.0.0 with line_level depth"

- `summary` — fast overview, counts affected files
- `file_level` — lists affected files with API usages (default)
- `line_level` — pinpoints exact lines with surrounding context

### 4. Generate a Migration Plan

For one or more upgrades, get an ordered action plan:

> "Generate a migration plan for upgrading provider to 7.0.0 and go_router to 14.0.0 in my project"

This produces:
- Ordered steps (dependency order is respected)
- Pubspec changes to make
- Code changes with before/after examples
- Commands to run (`dart pub get`, `dart fix --apply`, `dart test`)
- Effort estimate (trivial / low / medium / high)
- Prerequisites and warnings

### 5. Search for API Usages

Find where specific APIs are used in your codebase:

> "Search for usages of Provider.of and ChangeNotifierProvider in my project, filtering to the provider package"

This uses the Dart AST analyzer to find semantically accurate results, including resolved types, enclosing class/method, and the exact import source.

### 6. Fetch a Changelog

Read structured changelogs for any pub.dev package:

> "Fetch the changelog for the provider package between version 6.0.0 and 7.0.0"

Returns structured entries with version numbers, dates, categorized changes, and breaking change flags.

## Troubleshooting

### Server doesn't start

Check that `dart` is on your PATH:

```bash
which dart
```

Try running the server directly to see error output:

```bash
dart run /path/to/augur/bin/server.dart
```

The server logs to stderr, so you'll see any startup errors.

### "No pubspec.yaml found" error

Make sure you're passing the absolute path to the project root directory (the directory containing `pubspec.yaml`), not a subdirectory.

### Rate limiting from GitHub

If you see warnings about rate limiting, set up a `GITHUB_TOKEN`:

```bash
export GITHUB_TOKEN=ghp_your_token_here
```

Or add it to your MCP config's `env` block.

### Analysis is slow on large projects

For projects with thousands of files:

1. Use `summary` analysis depth first to get a quick overview
2. Use `file_level` for targeted analysis of specific packages
3. Set `MAX_FILES_TO_ANALYZE` if you need to cap the scan

### Cache issues

The cache is stored at `~/.augur/cache/` by default. To clear it:

```bash
rm -rf ~/.augur/cache/
```

Or set `CACHE_DIR` to a different location.

### Debug logging

Set `LOG_LEVEL=debug` to see detailed request/response logging:

```json
{
  "env": {
    "LOG_LEVEL": "debug"
  }
}
```

## Performance

Typical performance on an M1 Mac:

| Operation | ~2100 files | Notes |
|---|---|---|
| `scan_project` | <1s | YAML parsing only |
| `check_available_upgrades` (all deps) | 2-5s | Parallel pub.dev API calls, cached |
| `analyze_upgrade_impact` (summary) | 1-2s | Import scan only |
| `analyze_upgrade_impact` (file_level) | 3-6s | AST resolution on importing files |
| `analyze_upgrade_impact` (line_level) | 4-8s | Full AST + context extraction |
| `search_api_usage` | 3-6s | Full AST resolution |

Subsequent calls for the same package are faster due to caching (package metadata: 1hr, version details: 7 days, changelogs: 24hr).

## Next Steps

- Read the [README](../README.md) for architecture details
- Check [CONTRIBUTING.md](../CONTRIBUTING.md) if you want to contribute
- Browse the [tool reference](TOOL_REFERENCE.md) for complete input/output schemas
