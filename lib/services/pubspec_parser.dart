import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;

import '../models/pubspec_data.dart';
import '../utils/logger.dart';

/// Service that parses pubspec.yaml and pubspec.lock files from a Flutter/Dart
/// project and produces strongly-typed [PubspecData].
class PubspecParser {
  /// Parse the pubspec.yaml (and optionally pubspec.lock) located under
  /// [projectPath].
  ///
  /// When [includeDevDependencies] is `false`, the returned
  /// [PubspecData.devDependencies] will be an empty map.
  ///
  /// When [includeTransitive] is `true` and a lockfile is present, packages
  /// that appear in the lockfile but not in the direct dependency lists are
  /// added to [PubspecData.dependencies] with [DependencyInfo.isTransitive]
  /// set to `true`.
  Future<PubspecData> parse(
    String projectPath, {
    bool includeDevDependencies = true,
    bool includeTransitive = false,
  }) async {
    final pubspecFile = File(p.join(projectPath, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw ArgumentError('No pubspec.yaml found at $projectPath');
    }

    final pubspecContent = await pubspecFile.readAsString();
    final yaml = loadYaml(pubspecContent) as YamlMap;

    // --- SDK constraints ---------------------------------------------------
    final env = yaml['environment'] as YamlMap?;
    final sdkConstraints = SdkConstraints(
      dartSdk: env?['sdk']?.toString(),
      flutterSdk: env?['flutter']?.toString(),
    );

    // --- Direct dependencies ------------------------------------------------
    final deps =
        _parseDependencies(yaml['dependencies'] as YamlMap?, isDev: false);
    final devDeps = includeDevDependencies
        ? _parseDependencies(yaml['dev_dependencies'] as YamlMap?, isDev: true)
        : <String, DependencyInfo>{};

    // --- Lockfile -----------------------------------------------------------
    final lockFile = File(p.join(projectPath, 'pubspec.lock'));
    LockfileData? lockData;
    if (await lockFile.exists()) {
      try {
        lockData = await parseLockfile(lockFile);
        _mergeResolvedVersions(deps, lockData, isDev: false);
        _mergeResolvedVersions(devDeps, lockData, isDev: true);

        if (includeTransitive) {
          _addTransitiveDeps(deps, devDeps, lockData);
        }
      } catch (e, st) {
        Logger.warn(
          'Failed to parse pubspec.lock – resolved versions will be missing.',
        );
        Logger.debug('Lockfile parse error: $e\n$st');
      }
    } else {
      Logger.debug('No pubspec.lock found at $projectPath; skipping.');
    }

    return PubspecData(
      name: yaml['name']?.toString() ?? 'unknown',
      version: yaml['version']?.toString(),
      description: yaml['description']?.toString(),
      sdkConstraints: sdkConstraints,
      dependencies: deps,
      devDependencies: devDeps,
    );
  }

  // ---------------------------------------------------------------------------
  // Lockfile parsing
  // ---------------------------------------------------------------------------

  /// Parse a pubspec.lock [file] into a [LockfileData] model.
  ///
  /// The lockfile YAML structure looks like:
  /// ```yaml
  /// packages:
  ///   provider:
  ///     dependency: "direct main"
  ///     description:
  ///       name: provider
  ///       sha256: ...
  ///       url: "https://pub.dev"
  ///     source: hosted
  ///     version: "6.1.1"
  /// ```
  Future<LockfileData> parseLockfile(File file) async {
    final content = await file.readAsString();
    final yaml = loadYaml(content) as YamlMap;
    final packagesYaml = yaml['packages'] as YamlMap?;

    if (packagesYaml == null) {
      Logger.warn('Lockfile contains no "packages" key.');
      return const LockfileData(packages: {});
    }

    final packages = <String, LockfilePackage>{};

    for (final entry in packagesYaml.entries) {
      final name = entry.key.toString();
      final value = entry.value as YamlMap?;
      if (value == null) continue;

      final dependencyRaw = value['dependency'];
      final dependency = <String, String>{};
      if (dependencyRaw is YamlMap) {
        for (final d in dependencyRaw.entries) {
          dependency[d.key.toString()] = d.value?.toString() ?? '';
        }
      } else if (dependencyRaw is String) {
        // The common case: e.g. "direct main", "direct dev", "transitive"
        dependency['type'] = dependencyRaw;
      }

      // Description can be a map (hosted packages) or a simple string (sdk).
      String? descriptionStr;
      final descriptionRaw = value['description'];
      if (descriptionRaw is YamlMap) {
        // Build a human-readable representation while keeping the URL accessible.
        descriptionStr = _descriptionMapToString(descriptionRaw);
      } else if (descriptionRaw != null) {
        descriptionStr = descriptionRaw.toString();
      }

      packages[name] = LockfilePackage(
        name: name,
        version: value['version']?.toString() ?? '0.0.0',
        source: value['source']?.toString() ?? 'unknown',
        description: descriptionStr,
        dependency: dependency,
      );
    }

    Logger.debug('Parsed ${packages.length} packages from lockfile.');
    return LockfileData(packages: packages);
  }

  // ---------------------------------------------------------------------------
  // Dependency parsing helpers
  // ---------------------------------------------------------------------------

  /// Parse a `dependencies:` or `dev_dependencies:` YAML map into a typed map
  /// of [DependencyInfo] keyed by package name.
  ///
  /// Handles the multiple shapes a dependency entry can take:
  /// - **Simple version string**: `provider: ^6.0.0`
  /// - **Hosted map**: `provider: {hosted: {name: ..., url: ...}, version: ...}`
  /// - **Git map**: `provider: {git: {url: ..., ref: ...}}`
  /// - **Path map**: `provider: {path: ../local_pkg}`
  /// - **SDK map**: `provider: {sdk: flutter}`
  Map<String, DependencyInfo> _parseDependencies(
    YamlMap? depsYaml, {
    required bool isDev,
  }) {
    if (depsYaml == null) return {};

    final result = <String, DependencyInfo>{};

    for (final entry in depsYaml.entries) {
      final name = entry.key.toString();
      final value = entry.value;

      try {
        result[name] = _parseSingleDependency(name, value, isDev: isDev);
      } catch (e) {
        Logger.warn('Could not parse dependency "$name": $e');
        // Still record it with minimal info so it isn't silently dropped.
        result[name] = DependencyInfo(
          name: name,
          source: 'unknown',
          isDev: isDev,
        );
      }
    }

    return result;
  }

  /// Parse a single dependency entry (the value side of `name: <value>`).
  DependencyInfo _parseSingleDependency(
    String name,
    dynamic value, {
    required bool isDev,
  }) {
    // 1. Simple version constraint string — e.g. `^6.0.0`, `any`, `>=2.0.0 <3.0.0`
    if (value == null) {
      return DependencyInfo(
        name: name,
        source: 'hosted',
        versionConstraint: 'any',
        isDev: isDev,
      );
    }

    if (value is String) {
      return DependencyInfo(
        name: name,
        versionConstraint: value,
        source: 'hosted',
        isDev: isDev,
      );
    }

    // 2. Map form — could be git, path, sdk, or hosted with extra keys.
    if (value is YamlMap) {
      // --- Git dependency ---
      if (value.containsKey('git')) {
        final git = value['git'];
        String? url;
        String? ref;
        String? path;

        if (git is String) {
          url = git;
        } else if (git is YamlMap) {
          url = git['url']?.toString();
          ref = git['ref']?.toString();
          path = git['path']?.toString();
        }

        final versionParts = <String>[
          if (ref != null) 'ref: $ref',
          if (path != null) 'path: $path',
        ];

        return DependencyInfo(
          name: name,
          source: 'git',
          repositoryUrl: url,
          versionConstraint:
              versionParts.isNotEmpty ? versionParts.join(', ') : null,
          isDev: isDev,
        );
      }

      // --- Path dependency ---
      if (value.containsKey('path')) {
        return DependencyInfo(
          name: name,
          source: 'path',
          versionConstraint: value['path'].toString(),
          isDev: isDev,
        );
      }

      // --- SDK dependency ---
      if (value.containsKey('sdk')) {
        return DependencyInfo(
          name: name,
          source: 'sdk',
          versionConstraint: value['sdk'].toString(),
          isDev: isDev,
        );
      }

      // --- Hosted dependency with explicit hosted map ---
      if (value.containsKey('hosted')) {
        final hosted = value['hosted'];
        String? hostedUrl;

        if (hosted is String) {
          hostedUrl = hosted;
        } else if (hosted is YamlMap) {
          hostedUrl = hosted['url']?.toString();
        }

        return DependencyInfo(
          name: name,
          source: 'hosted',
          versionConstraint: value['version']?.toString(),
          repositoryUrl: hostedUrl,
          isDev: isDev,
        );
      }

      // --- Fallback: treat map with a `version` key as hosted ---
      if (value.containsKey('version')) {
        return DependencyInfo(
          name: name,
          source: 'hosted',
          versionConstraint: value['version'].toString(),
          isDev: isDev,
        );
      }

      // Unknown map shape — record what we can.
      Logger.debug(
        'Dependency "$name" has unrecognised map structure: $value',
      );
      return DependencyInfo(name: name, source: 'unknown', isDev: isDev);
    }

    // 3. Unexpected type.
    Logger.warn(
      'Dependency "$name" has unexpected type ${value.runtimeType}.',
    );
    return DependencyInfo(name: name, source: 'unknown', isDev: isDev);
  }

  // ---------------------------------------------------------------------------
  // Merging resolved versions from the lockfile
  // ---------------------------------------------------------------------------

  /// For every dependency in [deps], look up the matching package in
  /// [lockData] and replace the entry with one that includes the
  /// [DependencyInfo.resolvedVersion] and, where available, the repository URL.
  void _mergeResolvedVersions(
    Map<String, DependencyInfo> deps,
    LockfileData lockData, {
    required bool isDev,
  }) {
    for (final name in deps.keys.toList()) {
      final lockPkg = lockData.packages[name];
      if (lockPkg == null) continue;

      final existing = deps[name]!;
      deps[name] = DependencyInfo(
        name: existing.name,
        versionConstraint: existing.versionConstraint,
        resolvedVersion: lockPkg.version,
        source: existing.source,
        repositoryUrl:
            existing.repositoryUrl ?? _extractRepoUrl(lockPkg),
        isDev: existing.isDev,
        isTransitive: existing.isTransitive,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Transitive dependency collection
  // ---------------------------------------------------------------------------

  /// Add packages from the lockfile that are not already present in [deps] or
  /// [devDeps] as transitive dependencies in [deps].
  void _addTransitiveDeps(
    Map<String, DependencyInfo> deps,
    Map<String, DependencyInfo> devDeps,
    LockfileData lockData,
  ) {
    for (final entry in lockData.packages.entries) {
      final name = entry.key;
      if (deps.containsKey(name) || devDeps.containsKey(name)) continue;

      final lockPkg = entry.value;

      // Determine whether the lockfile considers this a dev transitive.
      final depType = lockPkg.dependency['type'] ?? '';
      final isDev = depType.contains('dev');

      deps[name] = DependencyInfo(
        name: name,
        resolvedVersion: lockPkg.version,
        source: lockPkg.source,
        repositoryUrl: _extractRepoUrl(lockPkg),
        isDev: isDev,
        isTransitive: true,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Utility helpers
  // ---------------------------------------------------------------------------

  /// Attempt to extract a repository or hosted URL from a [LockfilePackage].
  ///
  /// For hosted packages the description typically looks like:
  /// `name: foo, sha256: ..., url: https://pub.dev`
  ///
  /// For git packages the description contains the git URL.
  String? _extractRepoUrl(LockfilePackage lockPkg) {
    final desc = lockPkg.description;
    if (desc == null || desc.isEmpty) return null;

    // If the source is "git", the description itself is usually the URL or
    // contains it in a serialised form.
    if (lockPkg.source == 'git') {
      // The description is the serialised map — try to grab the URL.
      final urlMatch = RegExp(r'url:\s*(\S+)').firstMatch(desc);
      if (urlMatch != null) return urlMatch.group(1);
      // Might be a plain URL string.
      if (desc.startsWith('http://') || desc.startsWith('https://')) {
        return desc;
      }
      return null;
    }

    // For hosted packages, try to extract the `url:` field.
    if (lockPkg.source == 'hosted') {
      final urlMatch = RegExp(r'url:\s*(\S+)').firstMatch(desc);
      if (urlMatch != null) {
        final baseUrl = urlMatch.group(1)!;
        // Build a package-specific URL when the host is pub.dev.
        if (baseUrl.contains('pub.dev')) {
          return 'https://pub.dev/packages/${lockPkg.name}';
        }
        return baseUrl;
      }
    }

    return null;
  }

  /// Convert a YAML description map to a single string representation,
  /// preserving the URL for downstream extraction.
  String _descriptionMapToString(YamlMap map) {
    final parts = <String>[];
    for (final entry in map.entries) {
      final key = entry.key.toString();
      final value = entry.value?.toString() ?? '';
      parts.add('$key: $value');
    }
    return parts.join(', ');
  }
}
