/// Utilities for extracting structured data from Markdown changelogs
/// and documentation pages.
///
/// All methods are static and side-effect-free so they can be called from
/// anywhere without instantiation.
library;

/// A single section parsed from a Markdown document.
class MarkdownSection {

  const MarkdownSection({
    required this.heading,
    required this.level,
    required this.content,
    this.children = const [],
  });
  /// The heading text (without the leading `#` characters).
  final String heading;

  /// The heading level (1 for `#`, 2 for `##`, etc.).
  final int level;

  /// The body text that belongs to this section (everything between this
  /// heading and the next heading at the same or higher level).
  final String content;

  /// Nested sub-sections.
  final List<MarkdownSection> children;

  @override
  String toString() =>
      'MarkdownSection(level: $level, heading: "$heading", '
      'children: ${children.length})';
}

/// Static helpers for extracting structured data from Markdown text.
class MarkdownParser {
  MarkdownParser._();

  // ---------------------------------------------------------------------------
  // Section parsing
  // ---------------------------------------------------------------------------

  /// Pattern matching ATX headings (`# heading`, `## heading`, etc.).
  static final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.+)$');

  /// Parse [markdown] into a tree of [MarkdownSection]s organised by heading
  /// level.
  ///
  /// Top-level content that appears before any heading is ignored. The returned
  /// list contains only the root-level sections; deeper headings are nested in
  /// [MarkdownSection.children].
  static List<MarkdownSection> parseSections(String markdown) {
    final lines = markdown.split('\n');
    final rootSections = <MarkdownSection>[];

    // Flat list of (level, heading, startLine) tuples.
    final headings = <_HeadingInfo>[];

    for (var i = 0; i < lines.length; i++) {
      final match = _headingPattern.firstMatch(lines[i].trimRight());
      if (match != null) {
        headings.add(_HeadingInfo(
          level: match.group(1)!.length,
          heading: match.group(2)!.trim(),
          lineIndex: i,
        ));
      }
    }

    if (headings.isEmpty) return rootSections;

    // Build flat sections with raw content.
    final flatSections = <_FlatSection>[];
    for (var i = 0; i < headings.length; i++) {
      final start = headings[i].lineIndex + 1;
      final end =
          (i + 1 < headings.length) ? headings[i + 1].lineIndex : lines.length;
      final content = lines.sublist(start, end).join('\n').trim();
      flatSections.add(_FlatSection(
        level: headings[i].level,
        heading: headings[i].heading,
        content: content,
      ));
    }

    // Convert the flat list into a tree.
    return _buildTree(flatSections, 0, flatSections.length, 0);
  }

  /// Recursively build a tree of sections from a flat list slice.
  static List<MarkdownSection> _buildTree(
    List<_FlatSection> sections,
    int start,
    int end,
    int parentLevel,
  ) {
    final result = <MarkdownSection>[];
    var i = start;

    while (i < end) {
      final section = sections[i];

      // Find where this section's children end (next section at same or
      // higher level).
      var childEnd = i + 1;
      while (childEnd < end && sections[childEnd].level > section.level) {
        childEnd++;
      }

      final children = _buildTree(sections, i + 1, childEnd, section.level);

      result.add(MarkdownSection(
        heading: section.heading,
        level: section.level,
        content: section.content,
        children: children,
      ));

      i = childEnd;
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // Breaking changes
  // ---------------------------------------------------------------------------

  /// Markers that indicate a breaking change in changelog text.
  static final RegExp _breakingMarker = RegExp(
    r'(?:BREAKING|Breaking\s+Change|⚠️)',
    caseSensitive: false,
  );

  /// Extract breaking-change descriptions from [markdown].
  ///
  /// Heuristics:
  /// 1. Any heading containing "breaking" (case-insensitive) — the section
  ///    body is returned.
  /// 2. Any bullet or paragraph that contains one of the marker phrases
  ///    (`BREAKING`, `Breaking Change`, or the warning emoji `⚠️`).
  static List<String> extractBreakingChanges(String markdown) {
    final results = <String>[];
    final seen = <String>{};

    // Strategy 1: section-level headings.
    final sections = parseSections(markdown);
    _collectBreakingSections(sections, results, seen);

    // Strategy 2: line-level scanning for bullets / paragraphs.
    final lines = markdown.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (_breakingMarker.hasMatch(trimmed)) {
        // Strip leading bullet markers for cleanliness.
        final cleaned = trimmed
            .replaceFirst(RegExp(r'^[-*+]\s*'), '')
            .replaceFirst(RegExp(r'^\d+\.\s*'), '')
            .trim();
        if (cleaned.isNotEmpty && !seen.contains(cleaned)) {
          seen.add(cleaned);
          results.add(cleaned);
        }
      }
    }

    return results;
  }

  /// Walk the section tree and collect sections whose heading mentions
  /// "breaking".
  static void _collectBreakingSections(
    List<MarkdownSection> sections,
    List<String> results,
    Set<String> seen,
  ) {
    for (final section in sections) {
      if (section.heading.toLowerCase().contains('breaking')) {
        final text = '${section.heading}: ${section.content}'.trim();
        if (text.isNotEmpty && !seen.contains(text)) {
          seen.add(text);
          results.add(text);
        }
      }
      _collectBreakingSections(section.children, results, seen);
    }
  }

  // ---------------------------------------------------------------------------
  // API references
  // ---------------------------------------------------------------------------

  /// Pattern matching Dart-style API references:
  /// - `ClassName.methodName`
  /// - `functionName()`
  /// - `ClassName`  (PascalCase, at least 2 chars)
  /// - `package:foo/bar.dart`
  static final RegExp _apiRefPattern = RegExp(
    r'(?:'
    r'[A-Z][a-zA-Z0-9]*\.[a-zA-Z_][a-zA-Z0-9_]*' // ClassName.member
    r'|'
    r'[a-zA-Z_][a-zA-Z0-9_]*\(\)' // functionName()
    r'|'
    r'[A-Z][a-zA-Z0-9]{1,}' // PascalCase identifier
    r'|'
    r'package:[a-zA-Z_][a-zA-Z0-9_]*/[^\s]+\.dart' // package URI
    r')',
  );

  /// Extract Dart API references from [text].
  ///
  /// Returns a de-duplicated list in the order they first appear.
  static List<String> extractApiReferences(String text) {
    final matches = _apiRefPattern.allMatches(text);
    final seen = <String>{};
    final results = <String>[];

    for (final match in matches) {
      final value = match.group(0)!;
      // Filter out common English words that happen to be PascalCase.
      if (_commonWords.contains(value)) continue;
      if (seen.add(value)) {
        results.add(value);
      }
    }

    return results;
  }

  /// Words to exclude from API-reference extraction because they are normal
  /// English words that happen to satisfy PascalCase patterns.
  static const _commonWords = <String>{
    'The',
    'This',
    'That',
    'These',
    'Those',
    'When',
    'Where',
    'Which',
    'While',
    'With',
    'From',
    'Into',
    'After',
    'Before',
    'Between',
    'Through',
    'During',
    'Without',
    'About',
    'Above',
    'Below',
    'Also',
    'Added',
    'Changed',
    'Fixed',
    'Removed',
    'Updated',
    'See',
    'Use',
    'For',
    'New',
    'Now',
    'Note',
    'Please',
    'If',
    'In',
    'It',
    'An',
    'As',
    'At',
    'Be',
    'By',
    'Do',
    'Go',
    'He',
    'Is',
    'Me',
    'My',
    'No',
    'Of',
    'On',
    'Or',
    'So',
    'To',
    'Up',
    'Us',
    'We',
    'All',
    'And',
    'Are',
    'But',
    'Can',
    'Did',
    'Get',
    'Got',
    'Had',
    'Has',
    'Her',
    'Him',
    'His',
    'How',
    'Its',
    'Let',
    'May',
    'Not',
    'Old',
    'Our',
    'Out',
    'Own',
    'Put',
    'Say',
    'She',
    'Too',
    'Was',
    'Way',
    'Who',
    'Why',
    'Yet',
    'You',
    'BREAKING',
    'TODO',
    'NOTE',
    'WARNING',
    'DEPRECATED',
  };

  // ---------------------------------------------------------------------------
  // Code blocks
  // ---------------------------------------------------------------------------

  /// Pattern matching fenced code blocks (triple backticks with optional
  /// language tag).
  static final RegExp _codeBlockPattern = RegExp(
    r'```[a-zA-Z]*\n([\s\S]*?)```',
  );

  /// Extract the contents of all fenced code blocks from [markdown].
  ///
  /// Returns the raw code inside each block, without the fence markers or
  /// language tag.
  static List<String> extractCodeBlocks(String markdown) {
    return _codeBlockPattern
        .allMatches(markdown)
        .map((m) => m.group(1)!.trim())
        .where((block) => block.isNotEmpty)
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

class _HeadingInfo {

  const _HeadingInfo({
    required this.level,
    required this.heading,
    required this.lineIndex,
  });
  final int level;
  final String heading;
  final int lineIndex;
}

class _FlatSection {

  const _FlatSection({
    required this.level,
    required this.heading,
    required this.content,
  });
  final int level;
  final String heading;
  final String content;
}
