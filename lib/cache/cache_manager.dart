/// Two-tier cache: in-memory LRU + disk persistence with TTL.
///
/// The memory tier provides fast lookups while the disk tier ensures data
/// survives process restarts. Entries carry an expiration timestamp and are
/// transparently evicted when stale.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../utils/logger.dart';

/// A single cached value with expiry and LRU bookkeeping.
class _CacheEntry {
  final Map<String, dynamic> value;
  final DateTime expiresAt;
  DateTime lastAccessed;

  _CacheEntry({
    required this.value,
    required this.expiresAt,
    DateTime? lastAccessed,
  }) : lastAccessed = lastAccessed ?? DateTime.now();

  /// Whether this entry has passed its TTL.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Serialise to a JSON-safe map for disk persistence.
  Map<String, dynamic> toJson() => {
        'value': value,
        'expiresAt': expiresAt.toIso8601String(),
      };

  /// Reconstruct from a JSON map read from disk.
  factory _CacheEntry.fromJson(Map<String, dynamic> json) {
    return _CacheEntry(
      value: (json['value'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }
}

/// Manages a two-tier (memory + disk) cache with per-entry TTL.
///
/// Usage:
/// ```dart
/// final cache = CacheManager();
/// await cache.init();
/// await cache.set('key', {'data': 42}, CacheManager.packageMetadataTtl);
/// final result = await cache.get('key'); // {'data': 42}
/// ```
class CacheManager {
  /// Directory on disk where cached entries are stored as JSON files.
  final String _cacheDir;

  /// In-memory LRU map. Entries are ordered by insertion/access; the oldest
  /// entries are evicted first when the map exceeds [_maxMemoryEntries].
  final Map<String, _CacheEntry> _memoryCache = {};

  /// Upper bound on the number of entries kept in RAM.
  static const int _maxMemoryEntries = 500;

  // ---------------------------------------------------------------------------
  // Recommended TTL constants
  // ---------------------------------------------------------------------------

  /// TTL for pub.dev package metadata (versions list, etc.).
  static const Duration packageMetadataTtl = Duration(hours: 1);

  /// TTL for immutable version-specific data (a released version never
  /// changes).
  static const Duration versionDetailsTtl = Duration(days: 7);

  /// TTL for changelogs that may be updated with new releases.
  static const Duration changelogTtl = Duration(hours: 24);

  /// TTL for Flutter documentation pages.
  static const Duration flutterDocsTtl = Duration(hours: 24);

  // ---------------------------------------------------------------------------
  // Construction
  // ---------------------------------------------------------------------------

  /// Creates a new cache manager.
  ///
  /// The cache directory is resolved in order of precedence:
  /// 1. Explicit [cacheDir] parameter.
  /// 2. `CACHE_DIR` environment variable.
  /// 3. `$HOME/.augur/cache`.
  CacheManager({String? cacheDir})
      : _cacheDir = cacheDir ??
            Platform.environment['CACHE_DIR'] ??
            p.join(
              Platform.environment['HOME'] ?? '.',
              '.augur',
              'cache',
            );

  /// The resolved cache directory path.
  String get cacheDir => _cacheDir;

  /// Ensure the disk cache directory exists.
  Future<void> init() async {
    final dir = Directory(_cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      Logger.debug('Created cache directory: $_cacheDir');
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Retrieve a cached value by [key].
  ///
  /// Checks the memory tier first, then falls back to disk. Returns `null` if
  /// the key is not found or has expired.
  Future<Map<String, dynamic>?> get(String key) async {
    // --- Memory tier ---
    final memEntry = _memoryCache[key];
    if (memEntry != null) {
      if (memEntry.isExpired) {
        _memoryCache.remove(key);
        await _deleteDiskEntry(key);
        Logger.debug('Cache miss (expired in memory): $key');
        return null;
      }
      memEntry.lastAccessed = DateTime.now();
      // Move to end to maintain LRU ordering.
      _memoryCache.remove(key);
      _memoryCache[key] = memEntry;
      Logger.debug('Cache hit (memory): $key');
      return memEntry.value;
    }

    // --- Disk tier ---
    final diskEntry = await _readDiskEntry(key);
    if (diskEntry == null) {
      Logger.debug('Cache miss (not on disk): $key');
      return null;
    }
    if (diskEntry.isExpired) {
      await _deleteDiskEntry(key);
      Logger.debug('Cache miss (expired on disk): $key');
      return null;
    }

    // Promote to memory.
    _evictIfNeeded();
    _memoryCache[key] = diskEntry;
    Logger.debug('Cache hit (disk, promoted to memory): $key');
    return diskEntry.value;
  }

  /// Store a [value] under [key] with a given [ttl].
  ///
  /// The entry is written to both the memory and disk tiers.
  Future<void> set(
    String key,
    Map<String, dynamic> value,
    Duration ttl,
  ) async {
    final entry = _CacheEntry(
      value: value,
      expiresAt: DateTime.now().add(ttl),
    );

    // Memory tier.
    _evictIfNeeded();
    _memoryCache[key] = entry;

    // Disk tier.
    await _writeDiskEntry(key, entry);
    Logger.debug('Cache set: $key (ttl: ${ttl.inSeconds}s)');
  }

  /// Remove a specific [key] from both tiers.
  Future<void> remove(String key) async {
    _memoryCache.remove(key);
    await _deleteDiskEntry(key);
    Logger.debug('Cache remove: $key');
  }

  /// Remove all entries from both tiers.
  Future<void> clear() async {
    _memoryCache.clear();
    final dir = Directory(_cacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
    Logger.info('Cache cleared');
  }

  /// Number of entries currently in the memory tier (useful for diagnostics).
  int get memoryEntryCount => _memoryCache.length;

  // ---------------------------------------------------------------------------
  // LRU eviction
  // ---------------------------------------------------------------------------

  /// Evict the least-recently-accessed entries from the memory cache until the
  /// size is within [_maxMemoryEntries].
  void _evictIfNeeded() {
    while (_memoryCache.length >= _maxMemoryEntries) {
      // The first key in a LinkedHashMap is the oldest entry.
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
      Logger.debug('Evicted from memory cache: $oldestKey');
    }
  }

  // ---------------------------------------------------------------------------
  // Disk I/O
  // ---------------------------------------------------------------------------

  /// Produce a filesystem-safe filename by hashing the key with MD5.
  String _hashKey(String key) =>
      md5.convert(utf8.encode(key)).toString();

  /// Path to the JSON file for a given [key].
  String _diskPath(String key) =>
      p.join(_cacheDir, '${_hashKey(key)}.json');

  /// Read and deserialise a cache entry from disk, or return `null`.
  Future<_CacheEntry?> _readDiskEntry(String key) async {
    final file = File(_diskPath(key));
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return _CacheEntry.fromJson(json);
    } catch (e) {
      Logger.warn('Failed to read cache file for key "$key": $e');
      // Corrupted file — remove it so it does not cause repeated errors.
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
  }

  /// Serialise and write a cache entry to disk.
  Future<void> _writeDiskEntry(String key, _CacheEntry entry) async {
    final file = File(_diskPath(key));
    try {
      await file.writeAsString(jsonEncode(entry.toJson()));
    } catch (e) {
      Logger.warn('Failed to write cache file for key "$key": $e');
    }
  }

  /// Delete the disk file for a given [key], if it exists.
  Future<void> _deleteDiskEntry(String key) async {
    final file = File(_diskPath(key));
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      Logger.warn('Failed to delete cache file for key "$key": $e');
    }
  }
}
