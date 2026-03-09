# Changelog

## 1.0.0

Initial release.

### Tools
- `scan_project` — Scan pubspec.yaml and pubspec.lock for dependency inventory
- `check_available_upgrades` — Check pub.dev for available package upgrades
- `analyze_upgrade_impact` — Analyze breaking changes mapped to codebase via AST
- `generate_migration_plan` — Generate ordered migration steps for upgrades
- `fetch_changelog` — Fetch and parse structured changelogs
- `search_api_usage` — Search codebase for API usages with AST analysis

### Features
- AST-based code analysis via `package:analyzer` for 95%+ accuracy
- Multi-source breaking change detection (changelogs, GitHub releases, issues, Flutter docs)
- Cascading dependency conflict detection
- Risk scoring (0-10 scale) based on severity, coverage, and confidence
- Two-tier caching (in-memory LRU + disk with TTL)
- Topological sort for migration step ordering
- stdio MCP transport (compatible with Claude Code, Cursor, VS Code, Windsurf)
