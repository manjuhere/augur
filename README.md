# Augur

> Read the signs before you upgrade.

An MCP server that analyzes the impact of upgrading Flutter SDK and pub.dev dependencies in your codebase. Uses Dart's own AST analyzer for precise, semantic code analysis — no regex heuristics.

Works with **Claude Code**, **Cursor**, **VS Code Copilot**, **Windsurf**, and any MCP-compatible agent.

## Why This Exists

Upgrading Flutter SDK and pub.dev dependencies in large codebases is painful. Breaking changes are scattered across changelogs, release notes, and GitHub issues. The impact on a specific codebase is hard to assess without manually tracing every affected API.

Augur automates the entire analysis — fetching breaking change data from multiple sources and mapping them to exact files and lines in your codebase using Dart's AST analyzer.

Named after the [Augurs](https://en.wikipedia.org/wiki/Augur), Roman priests who read signs to predict outcomes — so you can foresee the impact of an upgrade before you make it.

## Key Features

- **AST-based code analysis** via `package:analyzer` — semantically resolves types, finds exact API usages, detects deprecated members
- **Multi-source breaking change detection** — changelogs, GitHub releases, GitHub issues, Flutter docs
- **Cascading dependency analysis** — detects when upgrading package A forces upgrades to B and C
- **Migration plan generation** — ordered steps with pubspec changes, code modifications, and commands
- **Risk scoring** — quantified risk assessment based on severity, codebase coverage, and confidence
- **Two-tier caching** — in-memory LRU + disk persistence to avoid redundant API calls

### AST vs Regex

| Capability | Regex | Dart AST |
|---|---|---|
| Find `Provider.of<T>()` calls | Pattern match, false positives in comments/strings | Exact semantic match |
| Handle re-exports | Misses indirect usages | Resolves through re-exports |
| Type inference | Cannot determine types | Full type resolution |
| Deprecated API detection | Must know deprecations upfront | Automatic via analyzer |
| Constructor vs factory calls | Fragile patterns | Exact element resolution |
| Confidence level | 60-80% | 95%+ |

## Tools

The server exposes 6 MCP tools:

### `scan_project`

Scan a Flutter/Dart project to discover all dependencies, versions, and SDK constraints.

```
Input:  projectPath, includeDevDependencies?, includeTransitive?
Output: project name, SDK constraints, full dependency inventory
```

### `check_available_upgrades`

Check pub.dev for available upgrades for all or specific dependencies.

```
Input:  projectPath, packageName?, includePrerelease?, targetFlutterVersion?
Output: per-dependency upgrade info (current vs latest, major/minor bump, retracted versions)
```

### `analyze_upgrade_impact`

The core tool. Analyze breaking changes between current and target version, mapped to your codebase via AST analysis.

```
Input:  projectPath, packageName, targetVersion, analysisDepth?, includeCascading?
Output: breaking changes with severity, affected file/line locations, suggested fixes, risk score
```

**Analysis depth options:**
- `summary` — fast overview, import-level only
- `file_level` — lists affected files with AST-resolved usages
- `line_level` — pinpoints exact code locations with surrounding context

### `generate_migration_plan`

Generate ordered, actionable migration steps for one or more upgrades.

```
Input:  projectPath, upgrades[], analysisDepth?
Output: ordered steps (pubspec changes, code changes, commands), effort estimate
```

### `fetch_changelog`

Fetch and parse raw changelog between two versions for any package.

```
Input:  packageName, fromVersion?, toVersion?, maxEntries?
Output: structured changelog entries with breaking change detection
```

### `search_api_usage`

Search codebase for specific API usages using AST analysis.

```
Input:  projectPath, apis[], packageFilter?
Output: per-API match results with file paths, line numbers, resolved types
```

## Quick Start

### Prerequisites

- Dart SDK 3.0 or later (Flutter devs already have this)

### Install from pub.dev (recommended)

```bash
dart pub global activate augur
```

This installs `augur` as a globally available command.

### Or install from source

```bash
git clone https://github.com/manjuhere/augur.git
cd augur
dart pub get
```

### Configure your MCP client

**Claude Code** — add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "augur": {
      "command": "augur"
    }
  }
}
```

**Cursor** — add to `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "augur": {
      "command": "augur"
    }
  }
}
```

**VS Code Copilot** — add to VS Code `settings.json`:

```json
{
  "mcpServers": {
    "augur": {
      "command": "augur"
    }
  }
}
```

> If you installed from source instead of pub.dev, use `"command": "dart"` with `"args": ["run", "/path/to/augur/bin/server.dart"]`.

For a detailed walkthrough, see [GETTING_STARTED.md](doc/GETTING_STARTED.md).

## Example Usage

Once configured, use the tools through your MCP-compatible agent:

> "Scan my Flutter project at /path/to/my_app and show me all dependencies"

> "Check what upgrades are available for my project"

> "Analyze the impact of upgrading provider to version 7.0.0 in my project"

> "Generate a migration plan for upgrading both provider to 7.0.0 and go_router to 14.0.0"

> "Find all usages of Provider.of in my codebase"

## Configuration

Environment variables:

| Variable | Description | Default |
|---|---|---|
| `GITHUB_TOKEN` | GitHub personal access token for higher API rate limits (60/hr without, 5000/hr with) | None |
| `CACHE_DIR` | Override cache directory location | `~/.augur/cache` |
| `LOG_LEVEL` | Logging verbosity: `debug`, `info`, `warn`, `error` | `info` |
| `MAX_FILES_TO_ANALYZE` | Upper limit on Dart files to scan per project | `5000` |

## Architecture

```
bin/server.dart              Entry point
lib/server.dart              MCP server setup + tool registration
lib/tools/                   6 tool implementations
lib/services/                Core logic
  ├── codebase_analyzer      AST-based Dart code analysis (package:analyzer)
  ├── pubspec_parser          pubspec.yaml/lock parsing
  ├── pub_api_client          pub.dev REST API
  ├── github_client           GitHub API (changelogs, releases, issues)
  ├── flutter_docs_client     Flutter breaking changes docs
  ├── changelog_parser        CHANGELOG.md structured parsing
  ├── version_resolver        Semantic version logic
  └── cascade_resolver        Cascading dependency detection
lib/models/                  Data models
lib/cache/                   In-memory LRU + disk cache with TTL
lib/utils/                   Logger (stderr-only), HTTP client, markdown parser
```

### Data Flow for `analyze_upgrade_impact`

```
1. Parse pubspec.yaml/lock → get current version
2. Fetch breaking change data in parallel:
   ├── CHANGELOG.md from GitHub
   ├── GitHub release notes
   ├── GitHub issues labeled "breaking-change"
   └── Flutter docs breaking changes (if flutter_sdk)
3. Extract affected API names from all sources
4. AST-based codebase analysis (depth-dependent):
   ├── summary:    count importing files
   ├── file_level: resolve AST, find API usages with element resolution
   └── line_level: same + line content, context, suggested fixes
5. Cascade analysis: check dependency conflicts
6. Risk assessment: severity x coverage x confidence → score (0-10)
```

## Development

```bash
# Install dependencies
dart pub get

# Run tests
dart test

# Run analyzer
dart analyze

# Run the server locally
dart run bin/server.dart
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License. See [LICENSE](LICENSE) for details.
