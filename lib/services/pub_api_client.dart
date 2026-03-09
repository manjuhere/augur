/// Client for the pub.dev REST API (https://pub.dev/api/).
///
/// Provides typed access to package metadata, version information, pubspec
/// contents, and package scores. All responses are cached via [CacheManager]
/// to avoid redundant network round-trips during a single upgrade analysis
/// session.
library;

import '../cache/cache_manager.dart';
import '../utils/http_client.dart';
import '../utils/logger.dart';

class PubApiClient {

  /// Creates a new pub.dev API client.
  ///
  /// An optional [httpClient] can be provided for testing; otherwise a default
  /// [HttpClientWrapper] is created automatically.
  PubApiClient({
    required CacheManager cacheManager,
    HttpClientWrapper? httpClient,
  })  : _cache = cacheManager,
        _http = httpClient ?? HttpClientWrapper();
  final HttpClientWrapper _http;
  final CacheManager _cache;

  static const _baseUrl = 'https://pub.dev/api';

  // ---------------------------------------------------------------------------
  // Package info
  // ---------------------------------------------------------------------------

  /// Get full package info from pub.dev.
  ///
  /// **GET** `/api/packages/{package}`
  ///
  /// Returns the full JSON response including `name`, `latest` (with `version`
  /// and `pubspec`), and `versions` (list of all published versions).
  ///
  /// Throws on non-2xx responses because downstream callers depend on this
  /// data being available.
  Future<Map<String, dynamic>> getPackageInfo(String packageName) async {
    final cacheKey = 'pub_package_$packageName';
    final cached = await _cache.get(cacheKey);
    if (cached != null) return cached;

    Logger.debug('Fetching package info for $packageName from pub.dev');
    final response = await _http.get('$_baseUrl/packages/$packageName');
    if (!response.isSuccess) {
      throw Exception(
        'Failed to fetch package info for $packageName: '
        'HTTP ${response.statusCode}',
      );
    }

    final data = response.json;
    await _cache.set(cacheKey, data, CacheManager.packageMetadataTtl);
    return data;
  }

  // ---------------------------------------------------------------------------
  // Versions
  // ---------------------------------------------------------------------------

  /// Get all published version strings for a package, sorted by publish order.
  ///
  /// Returns an empty list on failure rather than throwing.
  Future<List<String>> getVersions(String packageName) async {
    try {
      final info = await getPackageInfo(packageName);
      final versions = info['versions'] as List<dynamic>? ?? [];
      return versions
          .map((v) => (v as Map<String, dynamic>)['version'] as String)
          .toList();
    } catch (e, stack) {
      Logger.error('Failed to get versions for $packageName', e, stack);
      return [];
    }
  }

  /// Get detailed information for a specific version of a package.
  ///
  /// **GET** `/api/packages/{package}/versions/{version}`
  ///
  /// Returns `{version, pubspec, archive_url, ...}`. Returns `null` on
  /// failure.
  Future<Map<String, dynamic>?> getVersionInfo(
    String packageName,
    String version,
  ) async {
    final cacheKey = 'pub_version_${packageName}_$version';
    final cached = await _cache.get(cacheKey);
    if (cached != null) return cached;

    try {
      Logger.debug('Fetching version info for $packageName@$version');
      final response = await _http.get(
        '$_baseUrl/packages/$packageName/versions/$version',
      );
      if (!response.isSuccess) {
        Logger.warn(
          'Failed to fetch version info for $packageName@$version: '
          'HTTP ${response.statusCode}',
        );
        return null;
      }

      final data = response.json;
      // Version-specific data is immutable once published, so we can cache it
      // for a long time.
      await _cache.set(cacheKey, data, CacheManager.versionDetailsTtl);
      return data;
    } catch (e, stack) {
      Logger.error(
        'Error fetching version info for $packageName@$version',
        e,
        stack,
      );
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Pubspec
  // ---------------------------------------------------------------------------

  /// Get the pubspec for a specific version of a package.
  ///
  /// Extracts the `pubspec` field from the version info response. Returns
  /// `null` on failure.
  Future<Map<String, dynamic>?> getVersionPubspec(
    String packageName,
    String version,
  ) async {
    try {
      // First, try to extract from the full package info if already cached.
      // This avoids an extra HTTP request when the data is already available.
      final cacheKey = 'pub_package_$packageName';
      final cachedPackage = await _cache.get(cacheKey);
      if (cachedPackage != null) {
        final versions = cachedPackage['versions'] as List<dynamic>? ?? [];
        for (final v in versions) {
          final versionMap = v as Map<String, dynamic>;
          if (versionMap['version'] == version) {
            return versionMap['pubspec'] as Map<String, dynamic>?;
          }
        }
      }

      // Fall back to the version-specific endpoint.
      final versionInfo = await getVersionInfo(packageName, version);
      return versionInfo?['pubspec'] as Map<String, dynamic>?;
    } catch (e, stack) {
      Logger.error(
        'Error fetching pubspec for $packageName@$version',
        e,
        stack,
      );
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Score / metrics
  // ---------------------------------------------------------------------------

  /// Get the package score and metrics from pub.dev.
  ///
  /// **GET** `/api/packages/{package}/score`
  ///
  /// Returns `{grantedPoints, maxPoints, likeCount, ...}`. Returns `null` on
  /// failure.
  Future<Map<String, dynamic>?> getPackageScore(String packageName) async {
    final cacheKey = 'pub_score_$packageName';
    final cached = await _cache.get(cacheKey);
    if (cached != null) return cached;

    try {
      Logger.debug('Fetching package score for $packageName');
      final response = await _http.get(
        '$_baseUrl/packages/$packageName/score',
      );
      if (!response.isSuccess) {
        Logger.warn(
          'Failed to fetch score for $packageName: '
          'HTTP ${response.statusCode}',
        );
        return null;
      }

      final data = response.json;
      // Scores change slowly; cache for a moderate duration.
      await _cache.set(cacheKey, data, CacheManager.packageMetadataTtl);
      return data;
    } catch (e, stack) {
      Logger.error('Error fetching score for $packageName', e, stack);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Retraction check
  // ---------------------------------------------------------------------------

  /// Check whether a specific version of a package has been retracted.
  ///
  /// Retracted versions include a `retracted` field set to `true` in the
  /// versions list returned by `/api/packages/{package}`.
  ///
  /// Returns `false` on failure (assumes not retracted if we cannot verify).
  Future<bool> isVersionRetracted(
    String packageName,
    String version,
  ) async {
    try {
      final info = await getPackageInfo(packageName);
      final versions = info['versions'] as List<dynamic>? ?? [];
      for (final v in versions) {
        final versionMap = v as Map<String, dynamic>;
        if (versionMap['version'] == version) {
          return versionMap['retracted'] == true;
        }
      }
      // Version not found in the list — treat as not retracted.
      return false;
    } catch (e, stack) {
      Logger.error(
        'Error checking retraction status for $packageName@$version',
        e,
        stack,
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Repository URL
  // ---------------------------------------------------------------------------

  /// Get the repository URL for a package from its latest pubspec.
  ///
  /// Checks the `repository` field first, then falls back to `homepage`.
  /// Returns `null` if neither is present or on failure.
  Future<String?> getRepositoryUrl(String packageName) async {
    try {
      final info = await getPackageInfo(packageName);
      final latest = info['latest'] as Map<String, dynamic>?;
      if (latest == null) return null;

      final pubspec = latest['pubspec'] as Map<String, dynamic>?;
      if (pubspec == null) return null;

      // Prefer the explicit repository field.
      final repository = pubspec['repository'] as String?;
      if (repository != null && repository.isNotEmpty) return repository;

      // Fall back to homepage if it looks like a repo URL.
      final homepage = pubspec['homepage'] as String?;
      if (homepage != null && homepage.contains('github.com')) return homepage;

      return null;
    } catch (e, stack) {
      Logger.error(
        'Error fetching repository URL for $packageName',
        e,
        stack,
      );
      return null;
    }
  }
}
