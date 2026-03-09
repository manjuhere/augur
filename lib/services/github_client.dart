/// Client for the GitHub REST API and raw content endpoints.
///
/// Fetches changelogs, releases, breaking-change issues, and arbitrary file
/// content from public (and optionally private) GitHub repositories. Auth is
/// handled transparently by [HttpClientWrapper] when a `GITHUB_TOKEN`
/// environment variable is set.

import '../cache/cache_manager.dart';
import '../utils/http_client.dart';
import '../utils/logger.dart';

class GitHubClient {
  final HttpClientWrapper _http;
  final CacheManager _cache;

  static const _apiBase = 'https://api.github.com';
  static const _rawBase = 'https://raw.githubusercontent.com';

  /// Creates a new GitHub API client.
  ///
  /// An optional [httpClient] can be provided for testing; otherwise a default
  /// [HttpClientWrapper] is created automatically.
  GitHubClient({
    required CacheManager cacheManager,
    HttpClientWrapper? httpClient,
  })  : _cache = cacheManager,
        _http = httpClient ?? HttpClientWrapper();

  // ---------------------------------------------------------------------------
  // URL parsing
  // ---------------------------------------------------------------------------

  /// Extract the `(owner, repo)` pair from a GitHub URL.
  ///
  /// Handles common URL shapes:
  /// - `https://github.com/owner/repo`
  /// - `https://github.com/owner/repo.git`
  /// - `https://github.com/owner/repo/tree/main/...`
  /// - `git@github.com:owner/repo.git`
  ///
  /// Returns `null` if the URL cannot be parsed as a GitHub repository.
  static (String owner, String repo)? parseGitHubUrl(String url) {
    // Normalise: strip trailing slashes and `.git` suffix.
    var normalized = url.trim();

    // Handle SSH URLs: git@github.com:owner/repo.git
    if (normalized.startsWith('git@github.com:')) {
      normalized = normalized.substring('git@github.com:'.length);
      normalized = normalized.replaceAll(RegExp(r'\.git$'), '');
      final parts = normalized.split('/');
      if (parts.length >= 2) {
        return (parts[0], parts[1]);
      }
      return null;
    }

    // Handle HTTPS URLs.
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host != 'github.com') return null;

    // Path segments: ['', 'owner', 'repo', ...] (the leading '' comes from
    // the leading `/`).
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;

    final owner = segments[0];
    // Strip .git suffix if present.
    final repo = segments[1].replaceAll(RegExp(r'\.git$'), '');

    if (owner.isEmpty || repo.isEmpty) return null;
    return (owner, repo);
  }

  // ---------------------------------------------------------------------------
  // Changelog
  // ---------------------------------------------------------------------------

  /// Fetch the CHANGELOG content from a GitHub repository.
  ///
  /// Tries multiple common filenames in order: `CHANGELOG.md`, `changelog.md`,
  /// `CHANGES.md`, `HISTORY.md`. Returns the raw Markdown text, or `null` if
  /// no changelog is found.
  ///
  /// An optional [ref] (branch/tag/commit) can be specified; defaults to the
  /// repository's default branch.
  Future<String?> fetchChangelog(
    String owner,
    String repo, {
    String? ref,
  }) async {
    final branch = ref ?? 'main';
    final candidates = ['CHANGELOG.md', 'changelog.md', 'CHANGES.md', 'HISTORY.md'];

    for (final filename in candidates) {
      final content = await fetchFileContent(owner, repo, filename, ref: branch);
      if (content != null) {
        Logger.debug('Found changelog at $filename for $owner/$repo');
        return content;
      }
    }

    // Also try the `master` branch if the caller did not specify a ref and
    // `main` yielded nothing.
    if (ref == null) {
      for (final filename in candidates) {
        final content =
            await fetchFileContent(owner, repo, filename, ref: 'master');
        if (content != null) {
          Logger.debug(
            'Found changelog at $filename on master for $owner/$repo',
          );
          return content;
        }
      }
    }

    Logger.warn('No changelog found for $owner/$repo');
    return null;
  }

  // ---------------------------------------------------------------------------
  // Releases
  // ---------------------------------------------------------------------------

  /// Fetch GitHub releases for a repository.
  ///
  /// **GET** `/repos/{owner}/{repo}/releases`
  ///
  /// Returns a list of release objects, each containing `tag_name`, `name`,
  /// `body` (release notes), `published_at`, `prerelease`, etc.
  ///
  /// Returns an empty list on failure.
  Future<List<Map<String, dynamic>>> fetchReleases(
    String owner,
    String repo, {
    int perPage = 100,
  }) async {
    final cacheKey = 'github_releases_${owner}_$repo';
    final cached = await _cache.get(cacheKey);
    if (cached != null) {
      final entries = cached['entries'] as List<dynamic>? ?? [];
      return entries.cast<Map<String, dynamic>>();
    }

    try {
      Logger.debug('Fetching releases for $owner/$repo');
      final response = await _http.get(
        '$_apiBase/repos/$owner/$repo/releases?per_page=$perPage',
      );
      if (!response.isSuccess) {
        Logger.warn(
          'Failed to fetch releases for $owner/$repo: '
          'HTTP ${response.statusCode}',
        );
        return [];
      }

      final releases = response.jsonList
          .map((e) => e as Map<String, dynamic>)
          .toList();

      await _cache.set(
        cacheKey,
        {'entries': releases},
        CacheManager.changelogTtl,
      );
      return releases;
    } catch (e, stack) {
      Logger.error('Error fetching releases for $owner/$repo', e, stack);
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Breaking-change issues
  // ---------------------------------------------------------------------------

  /// Fetch closed issues labelled with breaking-change indicators.
  ///
  /// Searches for issues with the labels: `breaking-change`,
  /// `breaking change`, and `breaking`. Only closed issues are returned
  /// because open issues represent unreleased changes.
  ///
  /// Returns an empty list on failure.
  Future<List<Map<String, dynamic>>> fetchBreakingChangeIssues(
    String owner,
    String repo,
  ) async {
    final cacheKey = 'github_breaking_issues_${owner}_$repo';
    final cached = await _cache.get(cacheKey);
    if (cached != null) {
      final entries = cached['entries'] as List<dynamic>? ?? [];
      return entries.cast<Map<String, dynamic>>();
    }

    final allIssues = <Map<String, dynamic>>[];

    // Try several common label conventions.
    final labels = ['breaking-change', 'breaking change', 'breaking'];

    for (final label in labels) {
      try {
        final encodedLabel = Uri.encodeComponent(label);
        final response = await _http.get(
          '$_apiBase/repos/$owner/$repo/issues'
          '?labels=$encodedLabel&state=closed&per_page=100',
        );
        if (!response.isSuccess) continue;

        final issues = response.jsonList
            .map((e) => e as Map<String, dynamic>)
            .toList();

        // De-duplicate by issue number.
        final existingNumbers =
            allIssues.map((i) => i['number'] as int).toSet();
        for (final issue in issues) {
          final number = issue['number'] as int?;
          if (number != null && !existingNumbers.contains(number)) {
            allIssues.add(issue);
            existingNumbers.add(number);
          }
        }
      } catch (e) {
        Logger.warn(
          'Failed to fetch issues with label "$label" for $owner/$repo: $e',
        );
      }
    }

    Logger.debug(
      'Found ${allIssues.length} breaking-change issues for $owner/$repo',
    );

    await _cache.set(
      cacheKey,
      {'entries': allIssues},
      CacheManager.changelogTtl,
    );
    return allIssues;
  }

  // ---------------------------------------------------------------------------
  // Raw file content
  // ---------------------------------------------------------------------------

  /// Fetch the raw content of a file from a GitHub repository.
  ///
  /// Uses the `raw.githubusercontent.com` endpoint for efficiency (no JSON
  /// overhead, no base64 decoding required).
  ///
  /// An optional [ref] (branch/tag/SHA) can be specified; defaults to `main`.
  ///
  /// Returns `null` if the file does not exist or on failure.
  Future<String?> fetchFileContent(
    String owner,
    String repo,
    String path, {
    String? ref,
  }) async {
    final branch = ref ?? 'main';
    final cacheKey = 'github_file_${owner}_${repo}_${branch}_$path';
    final cached = await _cache.get(cacheKey);
    if (cached != null) {
      return cached['content'] as String?;
    }

    try {
      final url = '$_rawBase/$owner/$repo/$branch/$path';
      Logger.debug('Fetching file: $url');
      final response = await _http.get(url);

      if (!response.isSuccess) {
        // 404 is expected when probing for filenames; do not warn.
        if (response.statusCode != 404) {
          Logger.warn(
            'Failed to fetch $path from $owner/$repo@$branch: '
            'HTTP ${response.statusCode}',
          );
        }
        return null;
      }

      final content = response.body;
      await _cache.set(
        cacheKey,
        {'content': content},
        CacheManager.changelogTtl,
      );
      return content;
    } catch (e, stack) {
      Logger.error(
        'Error fetching $path from $owner/$repo@$branch',
        e,
        stack,
      );
      return null;
    }
  }
}
