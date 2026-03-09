# Contributing

Contributions are welcome. This document covers the process for contributing to Augur.

## Development Setup

```bash
git clone https://github.com/manjuhere/augur.git
cd augur
dart pub get
```

Verify everything works:

```bash
dart analyze
dart test
```

## Project Structure

```
lib/
├── server.dart              MCP server setup + tool registration
├── tools/                   Tool implementations (one per MCP tool)
├── services/                Core business logic
│   ├── codebase_analyzer    AST-based analysis (package:analyzer)
│   ├── pubspec_parser       pubspec.yaml/lock parsing
│   ├── pub_api_client       pub.dev API
│   ├── github_client        GitHub API
│   ├── flutter_docs_client  Flutter docs scraping
│   ├── changelog_parser     CHANGELOG.md parsing
│   ├── version_resolver     Semantic versioning
│   └── cascade_resolver     Dependency cascade detection
├── models/                  Data models with toJson()
├── cache/                   Two-tier cache (memory + disk)
└── utils/                   Logger, HTTP client, markdown parser
```

## Guidelines

### Code Style

- Follow the rules in `analysis_options.yaml`
- Run `dart analyze` before submitting — zero warnings expected
- Use single quotes for strings
- Prefer `const` constructors
- Never use `print()` — use `Logger` (writes to stderr only)

### Architecture

- **Tools** are thin wrappers that validate input and delegate to services
- **Services** contain the business logic and are independently testable
- **Models** are immutable data classes with `toJson()` methods
- Services receive their dependencies via constructor injection

### Logging

All logging goes to stderr via the `Logger` class. This is critical — stdout is reserved for the MCP protocol's JSON-RPC messages. Using `print()` or writing to stdout will break the MCP transport.

### Caching

- Cache keys should be descriptive: `pub_package_$name`, `github_changelog_$owner_$repo`
- Use the appropriate TTL constant from `CacheManager`
- Never cache codebase analysis results (code changes between calls)

### Testing

- Write unit tests for new services in `test/services/`
- Write tool-level tests in `test/tools/`
- Add test fixtures to `test/fixtures/` as needed
- Mock HTTP calls — don't make real network requests in tests

Run tests:

```bash
dart test                    # All tests
dart test test/services/     # Service tests only
dart test -r expanded        # Verbose output
```

## Pull Request Process

1. Fork the repository
2. Create a branch from `main` (`git checkout -b feature/my-feature`)
3. Make your changes
4. Ensure `dart analyze` shows zero errors/warnings (excluding test fixtures)
5. Ensure `dart test` passes
6. Submit a pull request with a clear description of the changes

### PR Title Format

- `feat: add support for workspace packages`
- `fix: handle missing CHANGELOG.md gracefully`
- `refactor: simplify risk score calculation`
- `docs: add examples for search_api_usage`
- `test: add tests for cascade_resolver`

## Adding a New Tool

1. Create the tool class in `lib/tools/your_tool.dart`
2. Add an `execute(Map<String, dynamic> args)` method
3. Register the tool in `lib/server.dart` with a JSON schema and callback
4. Add any new models to `lib/models/`
5. Export new models from `lib/augur.dart`
6. Add tests
7. Document the tool in `doc/TOOL_REFERENCE.md`

## Adding a New Service

1. Create the service in `lib/services/your_service.dart`
2. Accept dependencies via constructor parameters
3. Instantiate it in `AugurServer._initServices()`
4. Add tests with fixtures

## Reporting Issues

When reporting an issue, include:

- Dart SDK version (`dart --version`)
- The tool name and input parameters used
- The error message or unexpected behavior
- The project structure (if relevant, e.g., monorepo vs single package)
