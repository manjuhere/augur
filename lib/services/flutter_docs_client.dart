/// Client for fetching Flutter SDK breaking-change documentation.
///
/// Flutter documents breaking changes at:
///   https://docs.flutter.dev/release/breaking-changes
///
/// The source Markdown lives in the flutter/website repository on GitHub.
/// This client fetches and parses that index page to produce a structured
/// list of breaking changes, optionally filtered to a Flutter version range.
library;

import 'package:pub_semver/pub_semver.dart';

import '../cache/cache_manager.dart';
import '../utils/http_client.dart';
import '../utils/logger.dart';

class FlutterDocsClient {

  /// Creates a new Flutter docs client.
  ///
  /// An optional [httpClient] can be provided for testing; otherwise a default
  /// [HttpClientWrapper] is created automatically.
  FlutterDocsClient({
    required CacheManager cacheManager,
    HttpClientWrapper? httpClient,
  })  : _cache = cacheManager,
        _http = httpClient ?? HttpClientWrapper();
  final HttpClientWrapper _http;
  final CacheManager _cache;

  /// Raw Markdown URL for the breaking-changes index page in the
  /// flutter/website repo.
  static const _breakingChangesUrl =
      'https://raw.githubusercontent.com/flutter/website/main/'
      'src/content/release/breaking-changes/index.md';

  /// Alternative URL structure (the repo layout has changed over time).
  static const _breakingChangesUrlAlt =
      'https://raw.githubusercontent.com/flutter/website/main/'
      'src/release/breaking-changes/index.md';

  /// Base URL for individual breaking-change detail pages served via raw
  /// GitHub content.
  static const _breakingChangesDetailBase =
      'https://raw.githubusercontent.com/flutter/website/main/'
      'src/content/release/breaking-changes';

  // ---------------------------------------------------------------------------
  // All breaking changes
  // ---------------------------------------------------------------------------

  /// Fetch all known Flutter breaking changes from the documentation index.
  ///
  /// Returns a list of maps, each containing:
  /// - `title`   — human-readable title of the breaking change
  /// - `url`     — relative path or full URL to the detail page
  /// - `version` — Flutter version string where the change landed (if
  ///               extractable from the surrounding heading)
  ///
  /// Returns an empty list on failure.
  Future<List<Map<String, dynamic>>> fetchBreakingChanges() async {
    final cacheKey = 'flutter_breaking_changes';
    final cached = await _cache.get(cacheKey);
    if (cached != null) {
      final entries = cached['entries'] as List<dynamic>? ?? [];
      return entries.cast<Map<String, dynamic>>();
    }

    // Try primary URL first, then the alternative layout.
    String? markdown = await _fetchMarkdown(_breakingChangesUrl);
    markdown ??= await _fetchMarkdown(_breakingChangesUrlAlt);

    if (markdown == null) {
      Logger.warn('Could not fetch Flutter breaking-changes index');
      return [];
    }

    try {
      final entries = _parseBreakingChangesIndex(markdown);
      Logger.info('Parsed ${entries.length} Flutter breaking-change entries');

      await _cache.set(
        cacheKey,
        {'entries': entries},
        CacheManager.flutterDocsTtl,
      );
      return entries;
    } catch (e, stack) {
      Logger.error('Error parsing breaking-changes index', e, stack);
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Filtered by version range
  // ---------------------------------------------------------------------------

  /// Return breaking changes that apply when upgrading Flutter from
  /// [fromVersion] to [toVersion] (exclusive of `from`, inclusive of `to`).
  ///
  /// Changes whose version could not be determined are included as well since
  /// they may still be relevant.
  Future<List<Map<String, dynamic>>> getBreakingChangesForVersionRange(
    String fromVersion,
    String toVersion,
  ) async {
    final allChanges = await fetchBreakingChanges();
    if (allChanges.isEmpty) return [];

    try {
      final from = Version.parse(fromVersion);
      final to = Version.parse(toVersion);

      return allChanges.where((entry) {
        final versionStr = entry['version'] as String?;
        if (versionStr == null || versionStr.isEmpty) {
          // Include entries without a clear version — they may still be
          // relevant and the caller can further filter if needed.
          return true;
        }

        try {
          final version = Version.parse(versionStr);
          return version > from && version <= to;
        } catch (_) {
          // Unparseable version string — include by default.
          return true;
        }
      }).toList();
    } catch (e, stack) {
      Logger.error(
        'Error filtering breaking changes for range '
        '$fromVersion -> $toVersion',
        e,
        stack,
      );
      return allChanges;
    }
  }

  // ---------------------------------------------------------------------------
  // Individual detail pages
  // ---------------------------------------------------------------------------

  /// Fetch the full Markdown content for a specific breaking-change detail
  /// page.
  ///
  /// [path] should be the relative path or slug of the page (e.g.
  /// `"buttons"`, `"deprecated-api-removed-after-v3-16"`). The method
  /// attempts several URL patterns to locate the page.
  ///
  /// Returns `null` if the page cannot be found.
  Future<String?> fetchBreakingChangeDetail(String path) async {
    final cacheKey = 'flutter_breaking_change_detail_$path';
    final cached = await _cache.get(cacheKey);
    if (cached != null) {
      return cached['content'] as String?;
    }

    // Normalise: strip leading slashes and `.md` extension so we can
    // rebuild the URL predictably.
    var slug = path
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'\.md$'), '');

    // Also strip the leading path prefix if the caller passed a full
    // relative path from the index.
    slug = slug
        .replaceFirst(RegExp(r'^release/breaking-changes/'), '')
        .replaceFirst(RegExp(r'^breaking-changes/'), '');

    // Try several URL patterns — the directory structure has shifted between
    // website repo versions.
    final candidates = [
      '$_breakingChangesDetailBase/$slug.md',
      '$_breakingChangesDetailBase/$slug/index.md',
      'https://raw.githubusercontent.com/flutter/website/main/'
          'src/release/breaking-changes/$slug.md',
    ];

    for (final url in candidates) {
      final content = await _fetchMarkdown(url);
      if (content != null) {
        await _cache.set(
          cacheKey,
          {'content': content},
          CacheManager.flutterDocsTtl,
        );
        return content;
      }
    }

    Logger.warn('Could not fetch breaking-change detail for "$path"');
    return null;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Fetch raw Markdown from a URL. Returns `null` on any failure.
  Future<String?> _fetchMarkdown(String url) async {
    try {
      final response = await _http.get(url);
      if (!response.isSuccess) return null;
      return response.body;
    } catch (e) {
      Logger.debug('Failed to fetch $url: $e');
      return null;
    }
  }

  /// Parse the breaking-changes index Markdown into structured entries.
  ///
  /// The index page is organised with Markdown headings for each Flutter
  /// release version (e.g., `## Released in Flutter 3.24`) followed by
  /// bullet-point lists of links:
  ///
  /// ```
  /// ## Released in Flutter 3.24
  ///
  /// * [Some breaking change title](/release/breaking-changes/some-slug)
  /// * [Another change](/release/breaking-changes/another-slug)
  /// ```
  List<Map<String, dynamic>> _parseBreakingChangesIndex(String markdown) {
    final entries = <Map<String, dynamic>>[];
    String? currentVersion;

    // Regex for version headings like:
    //   ## Released in Flutter 3.24
    //   ## Not yet released
    //   ### Released in Flutter 3.19
    final versionHeadingPattern = RegExp(
      r'^#{2,3}\s+.*?(?:Released\s+in\s+Flutter\s+)(\d+\.\d+(?:\.\d+)?)',
      caseSensitive: false,
    );

    // Regex for section headings that do not contain a version (e.g.,
    // "## Not yet released", "## Reverted changes").
    final nonVersionHeadingPattern = RegExp(r'^#{2,3}\s+');

    // Regex for Markdown links in bullet points:
    //   * [Title](url)
    //   - [Title](url)
    final linkPattern = RegExp(r'^\s*[*\-]\s+\[(.+?)\]\((.+?)\)');

    for (final line in markdown.split('\n')) {
      // Check for a version heading.
      final versionMatch = versionHeadingPattern.firstMatch(line);
      if (versionMatch != null) {
        currentVersion = versionMatch.group(1);
        continue;
      }

      // Check for a non-version heading (resets version context).
      if (nonVersionHeadingPattern.hasMatch(line) && versionMatch == null) {
        // Only reset if this heading is at the same or higher level and does
        // not contain a version.
        if (!line.toLowerCase().contains('flutter')) {
          currentVersion = null;
        }
        continue;
      }

      // Check for a linked list item.
      final linkMatch = linkPattern.firstMatch(line);
      if (linkMatch != null) {
        final title = linkMatch.group(1)!.trim();
        final url = linkMatch.group(2)!.trim();

        entries.add({
          'title': title,
          'url': url,
          if (currentVersion != null) 'version': currentVersion,
        });
      }
    }

    return entries;
  }
}
