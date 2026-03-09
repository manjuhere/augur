/// Parses CHANGELOG.md content into structured entries with breaking change
/// detection.
///
/// Supports common changelog heading formats:
/// - `## 6.0.0`
/// - `## [6.0.0] - 2023-01-15`
/// - `## v6.0.0`
/// - `# 6.0.0`

import '../models/breaking_change.dart';
import '../utils/logger.dart';
import '../utils/markdown_parser.dart';

/// A single version entry parsed from a changelog.
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    this.date,
    required this.content,
    required this.hasBreakingChanges,
    required this.breakingChanges,
    required this.changes,
  });

  final String version;
  final String? date;
  final String content;
  final bool hasBreakingChanges;
  final List<BreakingChange> breakingChanges;
  final List<String> changes;

  Map<String, dynamic> toJson() => {
        'version': version,
        'date': date,
        'hasBreakingChanges': hasBreakingChanges,
        'breakingChanges': breakingChanges.map((b) => b.toJson()).toList(),
        'changes': changes,
      };

  @override
  String toString() =>
      'ChangelogEntry(version: $version, date: $date, '
      'breakingChanges: ${breakingChanges.length}, '
      'changes: ${changes.length})';
}

/// Parses raw CHANGELOG.md text into a list of [ChangelogEntry] objects.
class ChangelogParser {
  /// Pattern matching version headings in various common formats.
  ///
  /// Captures:
  ///   1. Version number (e.g. `6.0.0`, `6.0.0-beta.1`)
  ///   2. Optional date (e.g. `2023-01-15`)
  static final RegExp _versionHeadingPattern = RegExp(
    r'^#{1,3}\s+'
    r'(?:\[)?'
    r'v?(\d+\.\d+\.\d+(?:[+-][a-zA-Z0-9.]+)*)'
    r'(?:\](?:\([^)]*\))?)?'
    r'(?:\s*[-–—]\s*(\d{4}-\d{2}-\d{2}))?',
    multiLine: true,
  );

  /// Pattern matching individual bullet-point change lines.
  static final RegExp _bulletPattern = RegExp(r'^\s*[-*+]\s+(.+)$');

  /// Pattern matching numbered list items.
  static final RegExp _numberedPattern = RegExp(r'^\s*\d+\.\s+(.+)$');

  /// Keywords that signal a breaking change in a line of text.
  static final RegExp _breakingKeywords = RegExp(
    r'\b(?:BREAKING|breaking\s+change|⚠️|removed|deletion)\b',
    caseSensitive: false,
  );

  /// Keywords that indicate a replacement or migration path exists.
  static final RegExp _replacementPattern = RegExp(
    r'(?:use\s+`?(\w[\w.]*)`?\s+instead'
    r'|replace(?:d)?\s+(?:with|by)\s+`?(\w[\w.]*)`?'
    r'|migrate\s+to\s+`?(\w[\w.]*)`?'
    r'|→\s*`?(\w[\w.]*)`?)',
    caseSensitive: false,
  );

  /// Parse a full CHANGELOG.md into structured entries.
  ///
  /// Returns a list of [ChangelogEntry] objects sorted from newest to oldest
  /// (the order in which they appear in the file).
  List<ChangelogEntry> parse(String changelogContent) {
    if (changelogContent.trim().isEmpty) {
      Logger.debug('ChangelogParser: empty changelog content');
      return [];
    }

    final entries = <ChangelogEntry>[];

    // Find all version heading positions.
    final matches = _versionHeadingPattern.allMatches(changelogContent).toList();

    if (matches.isEmpty) {
      Logger.debug('ChangelogParser: no version headings found');
      return [];
    }

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final version = match.group(1)!;
      final date = match.group(2);

      // Extract the section content between this heading and the next.
      final sectionStart = match.end;
      final sectionEnd =
          (i + 1 < matches.length) ? matches[i + 1].start : changelogContent.length;
      final sectionContent = changelogContent.substring(sectionStart, sectionEnd).trim();

      // Parse individual change lines (bullets and numbered items).
      final changes = _extractChangeLines(sectionContent);

      // Detect and parse breaking changes.
      final breakingChanges = _extractBreakingChanges(version, sectionContent);

      entries.add(ChangelogEntry(
        version: version,
        date: date,
        content: sectionContent,
        hasBreakingChanges: breakingChanges.isNotEmpty,
        breakingChanges: breakingChanges,
        changes: changes,
      ));
    }

    Logger.debug('ChangelogParser: parsed ${entries.length} entries');
    return entries;
  }

  /// Get entries between two versions (exclusive of [fromVersion], inclusive of
  /// [toVersion]).
  ///
  /// Assumes [entries] are ordered newest-first (as returned by [parse]).
  /// Returns entries in the same newest-first order.
  List<ChangelogEntry> getEntriesBetween(
    List<ChangelogEntry> entries,
    String fromVersion,
    String toVersion,
  ) {
    if (entries.isEmpty) return [];

    // Build a simple comparable representation for version comparison.
    // We rely on string matching for boundary detection, then filter.
    final fromParts = _parseVersionParts(fromVersion);
    final toParts = _parseVersionParts(toVersion);

    if (fromParts == null || toParts == null) {
      Logger.warn(
        'ChangelogParser: could not parse version range '
        '$fromVersion..$toVersion',
      );
      return [];
    }

    return entries.where((entry) {
      final parts = _parseVersionParts(entry.version);
      if (parts == null) return false;
      // Exclusive of fromVersion, inclusive of toVersion.
      return _compareVersionParts(parts, fromParts) > 0 &&
          _compareVersionParts(parts, toParts) <= 0;
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Extract individual change lines from a section's content.
  List<String> _extractChangeLines(String content) {
    final changes = <String>[];
    final lines = content.split('\n');

    for (final line in lines) {
      final bulletMatch = _bulletPattern.firstMatch(line);
      if (bulletMatch != null) {
        changes.add(bulletMatch.group(1)!.trim());
        continue;
      }

      final numberedMatch = _numberedPattern.firstMatch(line);
      if (numberedMatch != null) {
        changes.add(numberedMatch.group(1)!.trim());
      }
    }

    return changes;
  }

  /// Extract breaking changes from a single version's changelog content.
  ///
  /// Uses [MarkdownParser.extractBreakingChanges] for detection and then
  /// enriches each result with severity, category, affected APIs, and
  /// replacement information.
  List<BreakingChange> _extractBreakingChanges(String version, String content) {
    final rawBreaking = MarkdownParser.extractBreakingChanges(content);
    if (rawBreaking.isEmpty) {
      // Fall back to keyword scanning on individual lines in case the
      // markdown parser missed inline markers.
      return _extractBreakingChangesFromLines(version, content);
    }

    final results = <BreakingChange>[];
    var index = 0;

    for (final description in rawBreaking) {
      final category = _detectCategory(description);
      final severity = _estimateSeverity(category, description);
      final apis = MarkdownParser.extractApiReferences(description);
      final replacement = _extractReplacement(description);
      final confidence = _estimateConfidence(description);

      results.add(BreakingChange(
        id: '${version}_breaking_$index',
        description: description,
        severity: severity,
        category: category,
        affectedApi: apis.isNotEmpty ? apis.first : null,
        replacement: replacement,
        migrationGuide: _extractMigrationGuide(description),
        confidence: confidence,
      ));
      index++;
    }

    // Also check for any breaking changes that the section parser might have
    // missed (inline markers without a dedicated section heading).
    final additionalFromLines = _extractBreakingChangesFromLines(
      version,
      content,
      existingDescriptions: rawBreaking.toSet(),
      startIndex: index,
    );
    results.addAll(additionalFromLines);

    return results;
  }

  /// Scan individual lines for breaking-change keywords that were not already
  /// captured by the section-level parser.
  List<BreakingChange> _extractBreakingChangesFromLines(
    String version,
    String content, {
    Set<String> existingDescriptions = const {},
    int startIndex = 0,
  }) {
    final results = <BreakingChange>[];
    final lines = content.split('\n');
    var index = startIndex;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!_breakingKeywords.hasMatch(trimmed)) continue;

      // Strip bullet markers for a clean description.
      final cleaned = trimmed
          .replaceFirst(RegExp(r'^[-*+]\s*'), '')
          .replaceFirst(RegExp(r'^\d+\.\s*'), '')
          .trim();

      if (cleaned.isEmpty) continue;

      // Skip if already captured.
      if (existingDescriptions.any(
        (existing) => existing.contains(cleaned) || cleaned.contains(existing),
      )) {
        continue;
      }

      final category = _detectCategory(cleaned);
      final severity = _estimateSeverity(category, cleaned);
      final apis = MarkdownParser.extractApiReferences(cleaned);
      final replacement = _extractReplacement(cleaned);
      final confidence = _estimateConfidence(cleaned);

      results.add(BreakingChange(
        id: '${version}_breaking_$index',
        description: cleaned,
        severity: severity,
        category: category,
        affectedApi: apis.isNotEmpty ? apis.first : null,
        replacement: replacement,
        migrationGuide: _extractMigrationGuide(cleaned),
        confidence: confidence,
      ));
      index++;
    }

    return results;
  }

  /// Detect the category of a breaking change from its description.
  ChangeCategory _detectCategory(String description) {
    final lower = description.toLowerCase();

    if (_matchesAny(lower, ['removed', 'deleted', 'no longer available'])) {
      return ChangeCategory.removal;
    }
    if (_matchesAny(lower, ['renamed', 'moved', 'name changed'])) {
      return ChangeCategory.rename;
    }
    if (_matchesAny(lower, [
      'parameter',
      'argument',
      'return type',
      'signature',
      'now accepts',
      'now returns',
      'no longer accepts',
    ])) {
      return ChangeCategory.signatureChange;
    }
    if (_matchesAny(lower, [
      'behavior',
      'behaviour',
      'default',
      'now requires',
      'semantics',
      'changed to',
    ])) {
      return ChangeCategory.behaviorChange;
    }
    if (_matchesAny(lower, ['deprecated', 'deprecation', 'will be removed'])) {
      return ChangeCategory.deprecation;
    }
    if (_matchesAny(lower, [
      'type',
      'generic',
      'typedef',
      'cast',
      'covariant',
    ])) {
      return ChangeCategory.typeChange;
    }

    // Default to behavior change when no specific pattern matches — it is the
    // safest assumption for an unclassified breaking change.
    return ChangeCategory.behaviorChange;
  }

  /// Estimate severity from the [category] and [description].
  Severity _estimateSeverity(ChangeCategory category, String description) {
    switch (category) {
      case ChangeCategory.removal:
        return Severity.critical;
      case ChangeCategory.signatureChange:
        return Severity.major;
      case ChangeCategory.typeChange:
        return Severity.major;
      case ChangeCategory.rename:
        // Renames usually have a straightforward replacement.
        return Severity.minor;
      case ChangeCategory.behaviorChange:
        // Behavior changes can be subtle and hard to detect at compile time.
        return Severity.major;
      case ChangeCategory.deprecation:
        // Deprecated APIs still work; this is informational.
        return Severity.info;
    }
  }

  /// Try to extract a replacement API name from the description.
  String? _extractReplacement(String description) {
    final match = _replacementPattern.firstMatch(description);
    if (match == null) return null;

    // Return the first non-null capture group.
    for (var i = 1; i <= match.groupCount; i++) {
      final group = match.group(i);
      if (group != null && group.isNotEmpty) return group;
    }

    return null;
  }

  /// Try to extract a migration guide snippet from the description.
  ///
  /// Looks for sentences containing migration-related keywords.
  String? _extractMigrationGuide(String description) {
    final sentences = description.split(RegExp(r'[.!]\s+'));
    for (final sentence in sentences) {
      final lower = sentence.toLowerCase();
      if (_matchesAny(lower, [
        'migrate',
        'migration',
        'instead',
        'replace',
        'upgrade',
        'switch to',
        'use the new',
      ])) {
        final trimmed = sentence.trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return null;
  }

  /// Estimate confidence based on how clear the breaking-change signal is.
  ///
  /// Returns a value between 0.0 and 1.0.
  double _estimateConfidence(String description) {
    final lower = description.toLowerCase();

    // Explicit markers are highest confidence.
    if (lower.contains('breaking change') || lower.contains('breaking:')) {
      return 1.0;
    }

    // Dedicated section headings with "breaking" are very clear.
    if (lower.startsWith('breaking')) {
      return 0.95;
    }

    // The ⚠️ emoji is a strong signal.
    if (description.contains('⚠️')) {
      return 0.9;
    }

    // Explicit removal language.
    if (_matchesAny(lower, ['removed', 'deleted', 'no longer available'])) {
      return 0.85;
    }

    // Less explicit keywords.
    if (_matchesAny(lower, ['renamed', 'moved', 'changed signature'])) {
      return 0.8;
    }

    // Behavioural signals are less certain.
    if (_matchesAny(lower, ['behavior', 'behaviour', 'now requires'])) {
      return 0.7;
    }

    // Catch-all for keyword matches that were not very specific.
    return 0.6;
  }

  /// Returns `true` if [text] contains any of the given [keywords].
  static bool _matchesAny(String text, List<String> keywords) {
    return keywords.any((keyword) => text.contains(keyword));
  }

  /// Parse a version string into a comparable list of integers.
  ///
  /// Returns `null` if the string cannot be parsed.
  static List<int>? _parseVersionParts(String version) {
    final cleaned = version.replaceFirst(RegExp(r'^v'), '');
    // Strip prerelease / build metadata for ordering purposes.
    final base = cleaned.split(RegExp(r'[+-]')).first;
    final segments = base.split('.');
    if (segments.length < 3) return null;

    try {
      return segments.map(int.parse).toList();
    } catch (_) {
      return null;
    }
  }

  /// Compare two version-part lists lexicographically.
  ///
  /// Returns negative if [a] < [b], zero if equal, positive if [a] > [b].
  static int _compareVersionParts(List<int> a, List<int> b) {
    final length = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final cmp = a[i].compareTo(b[i]);
      if (cmp != 0) return cmp;
    }
    return a.length.compareTo(b.length);
  }
}
