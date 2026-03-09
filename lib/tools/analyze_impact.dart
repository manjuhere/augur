/// Core tool for analyzing the impact of upgrading a package to a new version.
///
/// Orchestrates all services to:
/// 1. Resolve the current version from the project's pubspec/lockfile.
/// 2. Fetch breaking-change data from multiple sources in parallel.
/// 3. Map breaking changes to actual code locations via AST analysis.
/// 4. Detect cascading dependency conflicts.
/// 5. Compute a risk score and produce a structured [AnalysisResult].

import 'dart:async';
import 'dart:math' as math;

import '../models/analysis_result.dart';
import '../models/breaking_change.dart';
import '../models/api_usage.dart';
import '../services/pubspec_parser.dart';
import '../services/pub_api_client.dart';
import '../services/github_client.dart';
import '../services/flutter_docs_client.dart';
import '../services/changelog_parser.dart';
import '../services/codebase_analyzer.dart';
import '../services/version_resolver.dart';
import '../services/cascade_resolver.dart';
import '../utils/logger.dart';

class AnalyzeImpactTool {
  final PubspecParser _pubspecParser;
  final PubApiClient _pubApi;
  final GitHubClient _github;
  final FlutterDocsClient _flutterDocs;
  final ChangelogParser _changelogParser;
  final CodebaseAnalyzer _codebaseAnalyzer;
  final VersionResolver _versionResolver;
  final CascadeResolver _cascadeResolver;

  AnalyzeImpactTool({
    required PubspecParser pubspecParser,
    required PubApiClient pubApiClient,
    required GitHubClient githubClient,
    required FlutterDocsClient flutterDocsClient,
    required ChangelogParser changelogParser,
    required CodebaseAnalyzer codebaseAnalyzer,
    required VersionResolver versionResolver,
    required CascadeResolver cascadeResolver,
  })  : _pubspecParser = pubspecParser,
        _pubApi = pubApiClient,
        _github = githubClient,
        _flutterDocs = flutterDocsClient,
        _changelogParser = changelogParser,
        _codebaseAnalyzer = codebaseAnalyzer,
        _versionResolver = versionResolver,
        _cascadeResolver = cascadeResolver;

  /// Severity weights used in risk score calculation.
  static const _severityWeights = <Severity, double>{
    Severity.critical: 4.0,
    Severity.major: 3.0,
    Severity.minor: 2.0,
    Severity.info: 1.0,
  };

  /// Execute the analyze_upgrade_impact tool.
  ///
  /// Required parameters:
  /// - [projectPath]: absolute path to the Flutter/Dart project root.
  /// - [packageName]: the package to analyze.
  /// - [targetVersion]: the version to upgrade to.
  ///
  /// Optional parameters:
  /// - [analysisDepth]: `"summary"`, `"file_level"` (default), or `"line_level"`.
  /// - [includeCascading]: whether to check for cascading dependency impacts
  ///   (default `true`).
  ///
  /// Returns the [AnalysisResult] serialised as a JSON-compatible map.
  Future<Map<String, dynamic>> execute({
    required String projectPath,
    required String packageName,
    required String targetVersion,
    String analysisDepth = 'file_level',
    bool includeCascading = true,
  }) async {
    Logger.info(
      'Analyzing upgrade impact: $packageName -> $targetVersion '
      '($analysisDepth)',
    );

    // -------------------------------------------------------------------------
    // Step 1: Resolve the current version from pubspec / lockfile.
    // -------------------------------------------------------------------------
    final pubspec = await _pubspecParser.parse(projectPath);
    final currentDep = pubspec.dependencies[packageName] ??
        pubspec.devDependencies[packageName];
    final currentVersion = currentDep?.resolvedVersion;

    if (currentVersion == null) {
      throw ArgumentError(
        'Package $packageName not found in project or has no resolved version',
      );
    }

    Logger.info(
      'Current version of $packageName: $currentVersion -> $targetVersion',
    );

    final warnings = <String>[];
    final isMajor = _versionResolver.isMajorBump(currentVersion, targetVersion);
    if (isMajor) {
      warnings.add(
        'This is a major version bump ($currentVersion -> $targetVersion). '
        'Breaking changes are likely.',
      );
    }

    // -------------------------------------------------------------------------
    // Step 2: Fetch breaking-change data from all sources IN PARALLEL.
    // -------------------------------------------------------------------------
    final isFlutterSdk = packageName == 'flutter' ||
        packageName == 'flutter_sdk' ||
        currentDep?.source == 'sdk';

    // Launch all independent data fetches concurrently.
    final changelogEntriesFuture = _fetchChangelogEntries(
      packageName,
      currentVersion,
      targetVersion,
    );
    final releaseBreakingChangesFuture = _fetchReleaseBreakingChanges(
      packageName,
      currentVersion,
      targetVersion,
    );
    final issueBreakingChangesFuture = _fetchIssueBreakingChanges(
      packageName,
    );
    final flutterDocsChangesFuture = isFlutterSdk
        ? _flutterDocs.getBreakingChangesForVersionRange(
            currentVersion,
            targetVersion,
          )
        : Future.value(<Map<String, dynamic>>[]);
    final versionsFuture = _pubApi.getVersions(packageName);

    // Await all results together.
    final results = await Future.wait([
      changelogEntriesFuture, // [0] List<ChangelogEntry>
      releaseBreakingChangesFuture, // [1] List<BreakingChange>
      issueBreakingChangesFuture, // [2] List<BreakingChange>
      flutterDocsChangesFuture, // [3] List<Map<String, dynamic>>
      versionsFuture, // [4] List<String>
    ]);

    final changelogEntries = results[0] as List<ChangelogEntry>;
    final releaseBreakingChanges = results[1] as List<BreakingChange>;
    final issueBreakingChanges = results[2] as List<BreakingChange>;
    final flutterDocsChanges = results[3] as List<Map<String, dynamic>>;
    final allVersions = results[4] as List<String>;

    // Log version range information.
    final versionsInRange = _versionResolver.getVersionsInRange(
      allVersions,
      currentVersion,
      targetVersion,
    );
    Logger.info(
      'Found ${versionsInRange.length} version(s) between '
      '$currentVersion and $targetVersion',
    );

    // -------------------------------------------------------------------------
    // Step 2b: Merge and deduplicate breaking changes from all sources.
    // -------------------------------------------------------------------------
    final allBreakingChanges = <BreakingChange>[];

    // From CHANGELOG entries.
    for (final entry in changelogEntries) {
      allBreakingChanges.addAll(entry.breakingChanges);
    }

    // From GitHub releases.
    allBreakingChanges.addAll(releaseBreakingChanges);

    // From GitHub issues.
    allBreakingChanges.addAll(issueBreakingChanges);

    // From Flutter docs (convert maps to BreakingChange objects).
    for (final doc in flutterDocsChanges) {
      allBreakingChanges.add(_flutterDocToBreakingChange(doc));
    }

    // Deduplicate by affectedApi (prefer higher-confidence entries).
    final deduplicated = _deduplicateBreakingChanges(allBreakingChanges);

    Logger.info(
      'Collected ${allBreakingChanges.length} breaking change(s), '
      '${deduplicated.length} after deduplication',
    );

    if (deduplicated.isEmpty && isMajor) {
      warnings.add(
        'No breaking changes detected for a major version bump. '
        'This may indicate incomplete changelog data.',
      );
    }

    // -------------------------------------------------------------------------
    // Step 3: AST-based codebase analysis (depth-dependent).
    // -------------------------------------------------------------------------
    var totalFilesAffected = 0;
    var totalLocationsAffected = 0;
    var impacts = <BreakingChangeImpact>[];

    if (analysisDepth == 'summary') {
      // Summary mode: just count files importing the package; skip AST.
      totalFilesAffected = await _codebaseAnalyzer.countImportingFiles(
        projectPath,
        packageName,
      );
      Logger.info(
        'Summary mode: $totalFilesAffected file(s) import $packageName',
      );

      // Create impacts with empty locations for each breaking change.
      impacts = deduplicated
          .map((bc) => BreakingChangeImpact(
                breakingChange: bc,
                affectedLocations: const [],
                suggestedFix: _buildSuggestedFix(bc),
              ))
          .toList();

      // In summary mode, totalLocationsAffected is estimated as
      // totalFilesAffected (at least one usage per importing file).
      totalLocationsAffected = totalFilesAffected;
    } else {
      // file_level or line_level: use CodebaseAnalyzer.searchApiUsages
      // to find exact usages of affected APIs.
      final resolveTypes = analysisDepth == 'line_level';

      // Extract all affected API names from breaking changes.
      final affectedApis = _extractAffectedApis(deduplicated);

      if (affectedApis.isNotEmpty) {
        Logger.info(
          'Searching for ${affectedApis.length} affected API(s) '
          'in codebase (resolve=$resolveTypes)',
        );

        final usageResults = await _codebaseAnalyzer.searchApiUsages(
          projectPath: projectPath,
          apis: affectedApis,
          packageFilter: packageName,
          resolveTypes: resolveTypes,
        );

        // Build BreakingChangeImpact list mapping each breaking change to
        // the code locations that use its affected API.
        impacts = _buildImpacts(deduplicated, usageResults);

        // Compute totals.
        final allAffectedFiles = <String>{};
        for (final impact in impacts) {
          for (final loc in impact.affectedLocations) {
            allAffectedFiles.add(loc.filePath);
            totalLocationsAffected++;
          }
        }
        totalFilesAffected = allAffectedFiles.length;
      } else {
        // No affected APIs known, but we still know files that import
        // the package.
        totalFilesAffected = await _codebaseAnalyzer.countImportingFiles(
          projectPath,
          packageName,
        );
        impacts = deduplicated
            .map((bc) => BreakingChangeImpact(
                  breakingChange: bc,
                  affectedLocations: const [],
                  suggestedFix: _buildSuggestedFix(bc),
                ))
            .toList();

        if (deduplicated.isNotEmpty) {
          warnings.add(
            'Breaking changes were detected but none specify affected API '
            'names. Could not perform targeted codebase search. '
            '$totalFilesAffected file(s) import this package.',
          );
        }
      }

      Logger.info(
        'Codebase analysis: $totalFilesAffected file(s) affected, '
        '$totalLocationsAffected location(s)',
      );
    }

    // -------------------------------------------------------------------------
    // Step 4: Cascade analysis (if requested).
    // -------------------------------------------------------------------------
    var cascadingImpacts = <CascadingImpact>[];

    if (includeCascading) {
      try {
        cascadingImpacts = await _cascadeResolver.resolve(
          packageName: packageName,
          targetVersion: targetVersion,
          currentPubspec: pubspec,
        );
        if (cascadingImpacts.isNotEmpty) {
          Logger.info(
            'Found ${cascadingImpacts.length} cascading impact(s)',
          );
          warnings.add(
            '${cascadingImpacts.length} cascading dependency conflict(s) '
            'detected. Other packages may need to be upgraded simultaneously.',
          );
        }
      } catch (e) {
        Logger.warn('Cascade analysis failed: $e');
        warnings.add('Cascade analysis failed: $e');
      }
    }

    // -------------------------------------------------------------------------
    // Step 5: Risk assessment.
    // -------------------------------------------------------------------------
    final overallConfidence = _calculateOverallConfidence(deduplicated);
    final riskScore = _calculateRiskScore(
      impacts,
      totalFilesAffected,
      overallConfidence,
    );
    // Boost risk for cascading impacts.
    final adjustedScore = cascadingImpacts.isNotEmpty
        ? math.min(10.0, riskScore + cascadingImpacts.length * 0.5)
        : riskScore;
    final adjustedLevel = _riskLevelFromScore(adjustedScore);

    Logger.info(
      'Risk assessment: score=$adjustedScore, level=${adjustedLevel.name}, '
      'confidence=$overallConfidence',
    );

    // -------------------------------------------------------------------------
    // Build and return the result.
    // -------------------------------------------------------------------------
    final result = AnalysisResult(
      packageName: packageName,
      currentVersion: currentVersion,
      targetVersion: targetVersion,
      riskLevel: adjustedLevel,
      riskScore: adjustedScore,
      totalFilesAffected: totalFilesAffected,
      totalLocationsAffected: totalLocationsAffected,
      impacts: impacts,
      cascadingImpacts: cascadingImpacts,
      warnings: warnings,
      overallConfidence: overallConfidence,
    );

    return result.toJson();
  }

  // ===========================================================================
  // Data fetching helpers
  // ===========================================================================

  /// Fetch CHANGELOG entries between the current and target versions.
  ///
  /// Resolves the repository URL from pub.dev, fetches the CHANGELOG from
  /// GitHub, parses it, and filters to the relevant version range.
  Future<List<ChangelogEntry>> _fetchChangelogEntries(
    String packageName,
    String fromVersion,
    String toVersion,
  ) async {
    try {
      final repoUrl = await _pubApi.getRepositoryUrl(packageName);
      if (repoUrl == null) {
        Logger.debug('No repository URL found for $packageName');
        return [];
      }

      final parsed = GitHubClient.parseGitHubUrl(repoUrl);
      if (parsed == null) {
        Logger.debug('Could not parse GitHub URL: $repoUrl');
        return [];
      }

      final (owner, repo) = parsed;
      final changelogContent = await _github.fetchChangelog(owner, repo);
      if (changelogContent == null || changelogContent.isEmpty) {
        Logger.debug('No CHANGELOG found for $owner/$repo');
        return [];
      }

      final allEntries = _changelogParser.parse(changelogContent);
      final filtered = _changelogParser.getEntriesBetween(
        allEntries,
        fromVersion,
        toVersion,
      );

      Logger.debug(
        'CHANGELOG: ${allEntries.length} total entries, '
        '${filtered.length} in range $fromVersion..$toVersion',
      );
      return filtered;
    } catch (e) {
      Logger.warn('Failed to fetch changelog entries for $packageName: $e');
      return [];
    }
  }

  /// Fetch breaking changes from GitHub releases in the version range.
  ///
  /// Parses release bodies for breaking-change indicators and creates
  /// [BreakingChange] objects from them.
  Future<List<BreakingChange>> _fetchReleaseBreakingChanges(
    String packageName,
    String fromVersion,
    String toVersion,
  ) async {
    try {
      final repoUrl = await _pubApi.getRepositoryUrl(packageName);
      if (repoUrl == null) return [];

      final parsed = GitHubClient.parseGitHubUrl(repoUrl);
      if (parsed == null) return [];

      final (owner, repo) = parsed;
      final releases = await _github.fetchReleases(owner, repo);
      if (releases.isEmpty) return [];

      final breakingChanges = <BreakingChange>[];
      var index = 0;

      for (final release in releases) {
        final tagName = release['tag_name'] as String? ?? '';
        final releaseVersion = _extractVersionFromTag(tagName);
        if (releaseVersion == null) continue;

        // Filter to the version range.
        try {
          if (_versionResolver.compareVersions(
                    releaseVersion, fromVersion) <= 0 ||
              _versionResolver.compareVersions(
                    releaseVersion, toVersion) > 0) {
            continue;
          }
        } catch (_) {
          continue;
        }

        final body = release['body'] as String? ?? '';
        if (body.isEmpty) continue;

        // Look for breaking change indicators in the release body.
        final breakingLines = _extractBreakingLinesFromText(body);
        for (final line in breakingLines) {
          breakingChanges.add(BreakingChange(
            id: 'release_${releaseVersion}_$index',
            description: line,
            severity: _estimateSeverityFromText(line),
            category: _estimateCategoryFromText(line),
            affectedApi: _extractApiNameFromText(line),
            sourceUrl: release['html_url'] as String?,
            confidence: 0.7,
          ));
          index++;
        }
      }

      Logger.debug(
        'Releases: found ${breakingChanges.length} breaking change(s) '
        'from GitHub releases',
      );
      return breakingChanges;
    } catch (e) {
      Logger.warn('Failed to fetch release breaking changes: $e');
      return [];
    }
  }

  /// Fetch breaking-change issues from GitHub and convert to
  /// [BreakingChange] objects.
  Future<List<BreakingChange>> _fetchIssueBreakingChanges(
    String packageName,
  ) async {
    try {
      final repoUrl = await _pubApi.getRepositoryUrl(packageName);
      if (repoUrl == null) return [];

      final parsed = GitHubClient.parseGitHubUrl(repoUrl);
      if (parsed == null) return [];

      final (owner, repo) = parsed;
      final issues = await _github.fetchBreakingChangeIssues(owner, repo);
      if (issues.isEmpty) return [];

      final breakingChanges = <BreakingChange>[];
      for (var i = 0; i < issues.length; i++) {
        final issue = issues[i];
        final title = issue['title'] as String? ?? '';
        final body = issue['body'] as String? ?? '';
        final description =
            title.isNotEmpty ? title : body.split('\n').first;
        final htmlUrl = issue['html_url'] as String?;

        breakingChanges.add(BreakingChange(
          id: 'issue_${issue['number'] ?? i}',
          description: description,
          severity: _estimateSeverityFromText(description),
          category: _estimateCategoryFromText(description),
          affectedApi: _extractApiNameFromText(title.isNotEmpty ? title : body),
          sourceUrl: htmlUrl,
          confidence: 0.5, // Issues are less reliable than changelogs.
        ));
      }

      Logger.debug(
        'Issues: found ${breakingChanges.length} breaking-change issue(s)',
      );
      return breakingChanges;
    } catch (e) {
      Logger.warn('Failed to fetch issue breaking changes: $e');
      return [];
    }
  }

  // ===========================================================================
  // Breaking change analysis helpers
  // ===========================================================================

  /// Convert a Flutter docs breaking-change entry to a [BreakingChange].
  BreakingChange _flutterDocToBreakingChange(Map<String, dynamic> doc) {
    final title = doc['title'] as String? ?? 'Unknown breaking change';
    final url = doc['url'] as String?;
    return BreakingChange(
      id: 'flutter_docs_${title.hashCode.abs()}',
      description: title,
      severity: Severity.major,
      category: _estimateCategoryFromText(title),
      affectedApi: _extractApiNameFromText(title),
      sourceUrl: url != null
          ? (url.startsWith('http')
              ? url
              : 'https://docs.flutter.dev$url')
          : null,
      migrationGuide: url != null
          ? 'See migration guide: ${url.startsWith('http') ? url : 'https://docs.flutter.dev$url'}'
          : null,
      confidence: 0.9,
    );
  }

  /// Deduplicate breaking changes, preferring higher-confidence entries.
  ///
  /// Two breaking changes are considered duplicates if they share the same
  /// non-null [BreakingChange.affectedApi]. When both have null affectedApi,
  /// they are compared by description similarity.
  List<BreakingChange> _deduplicateBreakingChanges(
    List<BreakingChange> changes,
  ) {
    if (changes.length <= 1) return changes;

    final byApi = <String, BreakingChange>{};
    final noApi = <BreakingChange>[];

    for (final change in changes) {
      final api = change.affectedApi;
      if (api != null && api.isNotEmpty) {
        final existing = byApi[api];
        if (existing == null || change.confidence > existing.confidence) {
          byApi[api] = change;
        }
      } else {
        // No affected API: deduplicate by description similarity.
        final isDuplicate = noApi.any(
          (existing) => _isSimilarDescription(
            existing.description,
            change.description,
          ),
        );
        if (!isDuplicate) {
          noApi.add(change);
        }
      }
    }

    return [...byApi.values, ...noApi];
  }

  /// Rough similarity check: two descriptions are "similar" if one contains
  /// the other or if they share 80%+ of their words.
  bool _isSimilarDescription(String a, String b) {
    final normalA = a.toLowerCase().trim();
    final normalB = b.toLowerCase().trim();

    if (normalA.contains(normalB) || normalB.contains(normalA)) return true;

    final wordsA = normalA.split(RegExp(r'\s+')).toSet();
    final wordsB = normalB.split(RegExp(r'\s+')).toSet();
    if (wordsA.isEmpty || wordsB.isEmpty) return false;

    final intersection = wordsA.intersection(wordsB).length;
    final smaller = math.min(wordsA.length, wordsB.length);
    return intersection / smaller >= 0.8;
  }

  /// Extract all unique affected API identifiers from a list of breaking
  /// changes.
  List<String> _extractAffectedApis(List<BreakingChange> changes) {
    final apis = <String>{};
    for (final change in changes) {
      final api = change.affectedApi;
      if (api != null && api.isNotEmpty) {
        apis.add(api);
      }
    }
    return apis.toList();
  }

  // ===========================================================================
  // Impact building
  // ===========================================================================

  /// Map each breaking change to the code locations that reference its
  /// affected API.
  List<BreakingChangeImpact> _buildImpacts(
    List<BreakingChange> breakingChanges,
    List<ApiUsageResult> usageResults,
  ) {
    // Build a lookup: API name -> list of ApiMatch.
    final usageByApi = <String, List<ApiMatch>>{};
    for (final result in usageResults) {
      usageByApi[result.api] = result.matches;
    }

    final impacts = <BreakingChangeImpact>[];

    for (final bc in breakingChanges) {
      final api = bc.affectedApi;
      final matches = (api != null) ? (usageByApi[api] ?? const []) : const <ApiMatch>[];

      // Convert ApiMatch objects to CodeLocation objects.
      final locations = matches
          .map((m) => CodeLocation(
                filePath: m.filePath,
                line: m.line,
                column: m.column,
                lineContent: m.lineContent,
                surroundingContext: m.enclosingClass != null
                    ? '${m.enclosingClass}.${m.enclosingMethod ?? '<init>'}'
                    : m.enclosingMethod,
                resolvedType: m.resolvedType,
              ))
          .toList();

      impacts.add(BreakingChangeImpact(
        breakingChange: bc,
        affectedLocations: locations,
        suggestedFix: _buildSuggestedFix(bc),
      ));
    }

    return impacts;
  }

  /// Build a human-readable suggested fix string from a [BreakingChange].
  String? _buildSuggestedFix(BreakingChange change) {
    final parts = <String>[];

    if (change.replacement != null) {
      parts.add('Replace with `${change.replacement}`.');
    }

    if (change.migrationGuide != null) {
      parts.add(change.migrationGuide!);
    }

    switch (change.category) {
      case ChangeCategory.removal:
        if (change.replacement != null) {
          parts.add('The removed API has a replacement: `${change.replacement}`.');
        } else if (parts.isEmpty) {
          parts.add(
            'This API has been removed. Check the changelog for alternatives.',
          );
        }
        break;
      case ChangeCategory.rename:
        if (change.replacement != null) {
          parts.add('Rename all usages to `${change.replacement}`.');
        }
        break;
      case ChangeCategory.signatureChange:
        if (parts.isEmpty) {
          parts.add(
            'Method signature has changed. Review updated parameters.',
          );
        }
        break;
      case ChangeCategory.deprecation:
        if (parts.isEmpty) {
          parts.add(
            'This API is deprecated and may be removed in a future version.',
          );
        }
        break;
      case ChangeCategory.behaviorChange:
        if (parts.isEmpty) {
          parts.add(
            'Runtime behavior has changed. Review usage to ensure '
            'compatibility.',
          );
        }
        break;
      case ChangeCategory.typeChange:
        if (parts.isEmpty) {
          parts.add('Type has changed. Update type annotations and casts.');
        }
        break;
    }

    return parts.isNotEmpty ? parts.join(' ') : null;
  }

  // ===========================================================================
  // Risk scoring
  // ===========================================================================

  /// Calculate the overall confidence as a weighted average of all breaking
  /// changes' confidence values, weighted by their severity.
  double _calculateOverallConfidence(List<BreakingChange> changes) {
    if (changes.isEmpty) return 1.0;

    var weightedSum = 0.0;
    var totalWeight = 0.0;
    for (final change in changes) {
      final weight = _severityWeights[change.severity] ?? 1.0;
      weightedSum += change.confidence * weight;
      totalWeight += weight;
    }

    return totalWeight > 0 ? weightedSum / totalWeight : 1.0;
  }

  /// Calculate the risk score on a 0.0 to 10.0 scale.
  ///
  /// Formula:
  /// - For each breaking-change impact:
  ///     contribution = severity_weight * max(1, number_of_affected_locations)
  /// - raw_score = sum of contributions
  /// - coverage_factor = min(1.0, totalFiles / 100)
  ///   (normalises by project size; a package imported in 100+ files
  ///    is considered full coverage)
  /// - adjusted = raw_score * (0.5 + 0.5 * coverage_factor)
  /// - final = clamp(adjusted * confidence, 0.0, 10.0)
  double _calculateRiskScore(
    List<BreakingChangeImpact> impacts,
    int totalFiles,
    double confidence,
  ) {
    if (impacts.isEmpty) return 0.0;

    var rawScore = 0.0;
    for (final impact in impacts) {
      final weight =
          _severityWeights[impact.breakingChange.severity] ?? 1.0;
      // Each breaking change contributes at least its severity weight,
      // multiplied by the number of affected locations.
      final locationCount = math.max(1, impact.affectedLocations.length);
      rawScore += weight * locationCount;
    }

    // Normalize by total project files to get a coverage factor.
    // A package touching 100+ files is treated as full coverage.
    final coverageFactor = totalFiles > 0
        ? math.min(1.0, totalFiles / 100.0)
        : 0.1; // Small floor if we have no file count.

    // The base component (0.5) ensures that even low-coverage but
    // high-severity changes still register.
    final adjusted = rawScore * (0.5 + 0.5 * coverageFactor);

    // Apply confidence and clamp to [0, 10].
    final scaled = adjusted * confidence;

    // Scale so that a single critical change with 1 location scores ~2.0,
    // and saturates at 10.0 for many high-severity changes with broad
    // codebase coverage.
    final score = math.min(10.0, scaled);
    // Round to one decimal place for readability.
    return (score * 10).roundToDouble() / 10;
  }

  /// Map a numeric risk score to a [RiskLevel].
  RiskLevel _riskLevelFromScore(double score) {
    if (score >= 7.0) return RiskLevel.critical;
    if (score >= 4.0) return RiskLevel.high;
    if (score >= 2.0) return RiskLevel.medium;
    return RiskLevel.low;
  }

  // ===========================================================================
  // Text analysis utilities
  // ===========================================================================

  /// Extract a version string from a GitHub release tag name.
  ///
  /// Handles formats like `v6.0.0`, `6.0.0`, `package-v6.0.0`.
  String? _extractVersionFromTag(String tag) {
    final match = RegExp(r'v?(\d+\.\d+\.\d+(?:[+-][a-zA-Z0-9.]+)*)$')
        .firstMatch(tag);
    return match?.group(1);
  }

  /// Extract lines from text that indicate breaking changes.
  List<String> _extractBreakingLinesFromText(String text) {
    final breakingPattern = RegExp(
      r'\b(?:BREAKING|breaking\s+change|removed|deletion)\b',
      caseSensitive: false,
    );

    final lines = <String>[];
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (breakingPattern.hasMatch(trimmed)) {
        // Clean up bullet markers.
        final cleaned = trimmed
            .replaceFirst(RegExp(r'^[-*+]\s*'), '')
            .replaceFirst(RegExp(r'^\d+\.\s*'), '')
            .trim();
        if (cleaned.isNotEmpty) {
          lines.add(cleaned);
        }
      }
    }
    return lines;
  }

  /// Estimate severity from free-form text.
  Severity _estimateSeverityFromText(String text) {
    final lower = text.toLowerCase();
    if (_containsAny(lower, ['removed', 'deleted', 'no longer available'])) {
      return Severity.critical;
    }
    if (_containsAny(lower, [
      'breaking change',
      'breaking:',
      'signature',
      'parameter changed',
    ])) {
      return Severity.major;
    }
    if (_containsAny(lower, ['renamed', 'moved', 'deprecated'])) {
      return Severity.minor;
    }
    return Severity.major; // Default to major for unknown breaking changes.
  }

  /// Estimate change category from free-form text.
  ChangeCategory _estimateCategoryFromText(String text) {
    final lower = text.toLowerCase();
    if (_containsAny(lower, ['removed', 'deleted', 'no longer available'])) {
      return ChangeCategory.removal;
    }
    if (_containsAny(lower, ['renamed', 'moved', 'name changed'])) {
      return ChangeCategory.rename;
    }
    if (_containsAny(lower, [
      'parameter',
      'argument',
      'return type',
      'signature',
    ])) {
      return ChangeCategory.signatureChange;
    }
    if (_containsAny(lower, ['deprecated', 'deprecation'])) {
      return ChangeCategory.deprecation;
    }
    if (_containsAny(lower, ['type', 'generic', 'typedef'])) {
      return ChangeCategory.typeChange;
    }
    return ChangeCategory.behaviorChange;
  }

  /// Attempt to extract an API name (class/method/function) from text.
  ///
  /// Looks for backtick-quoted identifiers or PascalCase/camelCase words
  /// that look like Dart identifiers.
  String? _extractApiNameFromText(String text) {
    // First, try backtick-quoted identifiers.
    final backtickMatch = RegExp(r'`([A-Z]\w+(?:\.\w+)?)`').firstMatch(text);
    if (backtickMatch != null) return backtickMatch.group(1);

    // Try PascalCase class names (at least 2 uppercase transitions).
    final pascalMatch =
        RegExp(r'\b([A-Z][a-z]+[A-Z]\w+)\b').firstMatch(text);
    if (pascalMatch != null) return pascalMatch.group(1);

    // Try dotted identifiers like `ClassName.methodName`.
    final dottedMatch =
        RegExp(r'\b([A-Z]\w+\.\w+)\b').firstMatch(text);
    if (dottedMatch != null) return dottedMatch.group(1);

    return null;
  }

  /// Returns true if [text] contains any of the given [keywords].
  static bool _containsAny(String text, List<String> keywords) {
    return keywords.any((kw) => text.contains(kw));
  }
}
