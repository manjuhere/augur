# Tool Reference

Complete input/output schemas for all 6 MCP tools.

---

## `scan_project`

Scan a Flutter/Dart project to discover all dependencies, their current versions, version constraints, and SDK requirements.

### Input

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `projectPath` | string | Yes | — | Absolute path to the project root directory |
| `includeDevDependencies` | boolean | No | `true` | Include dev_dependencies in results |
| `includeTransitive` | boolean | No | `false` | Include transitive dependencies from pubspec.lock |

### Output

```json
{
  "projectName": "my_app",
  "version": "1.0.0+1",
  "description": "A Flutter application",
  "sdkConstraints": {
    "dartSdk": ">=3.0.0 <4.0.0",
    "flutterSdk": ">=3.10.0"
  },
  "dependencyCount": 10,
  "devDependencyCount": 5,
  "dependencies": {
    "provider": {
      "name": "provider",
      "versionConstraint": "^6.0.5",
      "resolvedVersion": "6.0.5",
      "source": "hosted",
      "repositoryUrl": "https://github.com/rrousselGit/provider",
      "isDev": false,
      "isTransitive": false
    }
  },
  "devDependencies": { ... }
}
```

---

## `check_available_upgrades`

Check pub.dev for available upgrades for all or specific dependencies.

### Input

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `projectPath` | string | Yes | — | Absolute path to the project root directory |
| `packageName` | string | No | — | Check a specific package only |
| `includePrerelease` | boolean | No | `false` | Include pre-release versions |
| `targetFlutterVersion` | string | No | — | Filter by Flutter SDK compatibility |

### Output

```json
{
  "projectName": "my_app",
  "packagesChecked": 10,
  "upgradesAvailable": 3,
  "upgrades": [
    {
      "packageName": "provider",
      "currentVersion": "6.0.5",
      "latestVersion": "7.0.0",
      "isUpToDate": false,
      "isMajorUpgrade": true,
      "isMinorUpgrade": false,
      "isRetracted": false,
      "constraintAllowsUpgrade": false,
      "suggestedConstraint": "^7.0.0",
      "isDev": false,
      "currentConstraint": "^6.0.5"
    }
  ]
}
```

---

## `analyze_upgrade_impact`

Analyze breaking changes between current and target version, mapped to your codebase via AST analysis.

### Input

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `projectPath` | string | Yes | — | Absolute path to the project root directory |
| `packageName` | string | Yes | — | Package to analyze (or `flutter_sdk`) |
| `targetVersion` | string | Yes | — | Version to upgrade to |
| `analysisDepth` | string | No | `file_level` | `summary`, `file_level`, or `line_level` |
| `includeCascading` | boolean | No | `true` | Check cascading dependency impacts |

### Output

```json
{
  "packageName": "provider",
  "currentVersion": "6.0.5",
  "targetVersion": "7.0.0",
  "riskLevel": "high",
  "riskScore": 6.2,
  "totalFilesAffected": 12,
  "totalLocationsAffected": 34,
  "impacts": [
    {
      "breakingChange": {
        "id": "provider-7.0.0-0",
        "description": "Removed Provider.of<T>() static method",
        "severity": "critical",
        "category": "removal",
        "affectedApi": "Provider.of",
        "replacement": "context.read<T>() or context.watch<T>()",
        "migrationGuide": "https://pub.dev/packages/provider/changelog#700",
        "sourceUrl": "https://github.com/rrousselGit/provider/blob/main/CHANGELOG.md",
        "confidence": 1.0
      },
      "affectedLocations": [
        {
          "filePath": "/path/to/my_app/lib/pages/home_page.dart",
          "line": 42,
          "column": 21,
          "lineContent": "final counter = Provider.of<CounterModel>(context);",
          "surroundingContext": "HomePage.build",
          "resolvedType": "CounterModel"
        }
      ],
      "suggestedFix": "Replace Provider.of<T>() with context.read<T>() or context.watch<T>()"
    }
  ],
  "cascadingImpacts": [
    {
      "dependencyName": "flutter_bloc",
      "requiredBy": "provider@7.0.0",
      "currentConstraint": "8.1.3",
      "conflictReason": "Requires flutter_bloc >=9.0.0 but current version is 8.1.3"
    }
  ],
  "warnings": [
    "Could not fetch GitHub release notes — reduced confidence"
  ],
  "overallConfidence": 0.85
}
```

### Risk Score

The risk score (0.0–10.0) is calculated as:

```
rawScore = sum(severity_weight * location_count) for each breaking change

  severity weights: critical=4, major=3, minor=2, info=1

coverageFactor = min(1.0, totalFilesAffected / 100)
adjusted = rawScore * (0.5 + 0.5 * coverageFactor)
finalScore = min(10.0, adjusted * confidence)
```

Risk levels:
- **low**: score < 2.0
- **medium**: 2.0 to 4.0
- **high**: 4.0 to 7.0
- **critical**: 7.0+

---

## `generate_migration_plan`

Generate ordered, actionable migration steps for one or more upgrades.

### Input

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `projectPath` | string | Yes | — | Absolute path to the project root directory |
| `upgrades` | array | Yes | — | List of `{packageName, targetVersion}` objects |
| `analysisDepth` | string | No | `file_level` | Analysis depth for impact analysis |

### Output

```json
{
  "steps": [
    {
      "order": 1,
      "type": "pubspecChange",
      "description": "Update provider to 7.0.0 in pubspec.yaml",
      "packageName": "provider",
      "targetVersion": "7.0.0",
      "codeChanges": [
        {
          "filePath": "pubspec.yaml",
          "line": 0,
          "before": "provider: ^6.0.5",
          "after": "provider: ^7.0.0",
          "explanation": "Update version constraint for provider to allow 7.0.0"
        }
      ]
    },
    {
      "order": 2,
      "type": "runCommand",
      "description": "Resolve updated dependencies for provider",
      "packageName": "provider",
      "command": "dart pub get"
    },
    {
      "order": 3,
      "type": "codeChange",
      "description": "Removed Provider.of<T>() static method (API: Provider.of)",
      "packageName": "provider",
      "targetVersion": "7.0.0",
      "codeChanges": [
        {
          "filePath": "lib/pages/home_page.dart",
          "line": 42,
          "before": "final counter = Provider.of<CounterModel>(context);",
          "after": "Replace Provider.of<T>() with context.read<T>() or context.watch<T>()",
          "explanation": "Removed Provider.of<T>() static method"
        }
      ]
    },
    {
      "order": 4,
      "type": "runCommand",
      "description": "Apply automated dart fix suggestions for provider",
      "packageName": "provider",
      "command": "dart fix --apply"
    },
    {
      "order": 5,
      "type": "runCommand",
      "description": "Run all tests to verify migration",
      "command": "dart test"
    }
  ],
  "estimatedEffort": "medium",
  "effortDescription": "Moderate refactoring needed for 2 packages. Plan for focused development time (1-4 hours).",
  "prerequisites": [
    "Ensure all tests pass before starting migration",
    "Create a backup branch: git checkout -b pre-migration-backup",
    "Ensure you have a clean working tree (no uncommitted changes)"
  ],
  "warnings": [
    "Cascading impact: flutter_bloc may need updating due to provider upgrade"
  ]
}
```

**Step types:**
- `pubspecChange` — Modify pubspec.yaml
- `codeChange` — Manual code modifications needed
- `runCommand` — Shell command to execute
- `manual` — Manual review/action required

**Effort levels:**
- `trivial` — Mostly pubspec updates
- `low` — A few code changes
- `medium` — Moderate refactoring (1-4 hours)
- `high` — Significant effort, consider splitting into smaller PRs (4+ hours)

---

## `fetch_changelog`

Fetch and parse raw changelog between two versions for any package.

### Input

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `packageName` | string | Yes | — | The pub.dev package name |
| `fromVersion` | string | No | — | Start of version range (exclusive) |
| `toVersion` | string | No | — | End of version range (inclusive) |
| `maxEntries` | integer | No | `50` | Maximum entries to return |

### Output

```json
{
  "packageName": "provider",
  "fromVersion": "6.0.0",
  "toVersion": "7.0.0",
  "entryCount": 4,
  "hasBreakingChanges": true,
  "entries": [
    {
      "version": "7.0.0",
      "date": "2024-01-15",
      "hasBreakingChanges": true,
      "breakingChanges": [
        {
          "id": "provider-7.0.0-0",
          "description": "Removed Provider.of<T>() static method",
          "severity": "critical",
          "category": "removal",
          "affectedApi": "Provider",
          "replacement": "context.read<T>() or context.watch<T>()",
          "confidence": 0.9
        }
      ],
      "changes": [
        "Added context.select<T, R>() for fine-grained rebuilds",
        "Improved error messages for missing providers"
      ]
    }
  ]
}
```

---

## `search_api_usage`

Search codebase for specific API usages using AST analysis.

### Input

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `projectPath` | string | Yes | — | Absolute path to the project root directory |
| `apis` | array of strings | Yes | — | API identifiers to search for |
| `packageFilter` | string | No | — | Only match usages from this package |

### Output

```json
{
  "searchedApis": ["Provider.of", "ChangeNotifierProvider"],
  "packageFilter": "provider",
  "results": [
    {
      "api": "Provider.of",
      "packageFilter": "provider",
      "totalMatches": 5,
      "matches": [
        {
          "filePath": "/path/to/lib/pages/home_page.dart",
          "line": 42,
          "column": 21,
          "lineContent": "final counter = Provider.of<CounterModel>(context);",
          "resolvedType": "CounterModel Function(BuildContext, {bool listen})",
          "enclosingClass": "HomePage",
          "enclosingMethod": "build",
          "importSource": "package:provider/provider.dart"
        }
      ]
    }
  ],
  "totalMatches": 8
}
```

### API Name Formats

The `apis` parameter accepts various formats:

- `Provider` — matches the class name
- `Provider.of` — matches the specific method on the class
- `of` — matches any method named `of` (less specific)
- `ChangeNotifierProvider` — matches the class
- `context.read` — matches the extension method

When `packageFilter` is set, only usages originating from that package are returned, eliminating false positives from identically-named APIs in other packages.
