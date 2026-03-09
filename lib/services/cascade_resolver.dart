/// Resolves cascading dependency impacts when upgrading packages.
///
/// When upgrading package A to a new version, the new version may require
/// different versions of its own dependencies. If any of those transitive
/// requirements conflict with the project's current lockfile, they are
/// reported as [CascadingImpact]s.

import '../models/analysis_result.dart';
import '../models/pubspec_data.dart';
import '../utils/logger.dart';
import 'pub_api_client.dart';
import 'version_resolver.dart';

/// Resolves cascading dependency impacts for package upgrades.
class CascadeResolver {
  CascadeResolver(this._pubApi, this._versionResolver);

  final PubApiClient _pubApi;
  final VersionResolver _versionResolver;

  /// Check for cascading impacts of upgrading [packageName] to
  /// [targetVersion].
  ///
  /// Process:
  /// 1. Fetch the target version's pubspec from pub.dev.
  /// 2. Collect its declared dependencies and their version constraints.
  /// 3. Compare each constraint against the version currently resolved in
  ///    the project's lockfile / pubspec.
  /// 4. Report any dependency whose current resolved version does not
  ///    satisfy the target's constraint as a [CascadingImpact].
  Future<List<CascadingImpact>> resolve({
    required String packageName,
    required String targetVersion,
    required PubspecData currentPubspec,
  }) async {
    final impacts = <CascadingImpact>[];

    try {
      // Fetch the pubspec of the version we want to upgrade to.
      final targetPubspec = await _pubApi.getVersionPubspec(
        packageName,
        targetVersion,
      );

      if (targetPubspec == null) {
        Logger.warn(
          'CascadeResolver: could not fetch pubspec for '
          '$packageName@$targetVersion',
        );
        return impacts;
      }

      final targetDeps =
          targetPubspec['dependencies'] as Map<String, dynamic>? ?? {};

      for (final entry in targetDeps.entries) {
        final depName = entry.key;
        final constraint = _extractConstraint(entry.value);
        if (constraint == null) continue;

        // Look up the dependency in the current project.
        final currentDep = currentPubspec.dependencies[depName] ??
            currentPubspec.devDependencies[depName];

        // If the project does not use this dependency at all it will be
        // pulled in transitively — no conflict.
        if (currentDep == null || currentDep.resolvedVersion == null) continue;

        final currentVersion = currentDep.resolvedVersion!;

        // Check if the currently resolved version satisfies the target's
        // constraint.
        if (!_versionResolver.satisfies(currentVersion, constraint)) {
          impacts.add(CascadingImpact(
            dependencyName: depName,
            requiredBy: '$packageName@$targetVersion',
            currentConstraint: currentVersion,
            conflictReason:
                'Requires $depName $constraint but current version '
                'is $currentVersion',
          ));
        }
      }
    } catch (e, st) {
      Logger.warn(
        'Failed to resolve cascading impacts for $packageName: $e',
      );
      Logger.debug('Stack trace: $st');
    }

    if (impacts.isNotEmpty) {
      Logger.info(
        'CascadeResolver: found ${impacts.length} cascading impact(s) '
        'for $packageName@$targetVersion',
      );
    }

    return impacts;
  }

  /// Check if multiple simultaneous upgrades have conflicts with each other.
  ///
  /// For every pair of planned upgrades, this fetches each target version's
  /// dependency map and verifies that they are mutually satisfiable. It also
  /// checks each upgrade's requirements against the current pubspec.
  ///
  /// [upgrades] is a list of maps, each containing `packageName` and
  /// `targetVersion` keys.
  Future<List<CascadingImpact>> checkCrossUpgradeConflicts(
    List<Map<String, String>> upgrades,
    PubspecData currentPubspec,
  ) async {
    if (upgrades.length < 2) {
      // A single upgrade cannot conflict with itself; delegate to [resolve].
      if (upgrades.length == 1) {
        return resolve(
          packageName: upgrades.first['packageName']!,
          targetVersion: upgrades.first['targetVersion']!,
          currentPubspec: currentPubspec,
        );
      }
      return [];
    }

    final impacts = <CascadingImpact>[];

    // Fetch all target pubspecs in parallel.
    final pubspecFutures = <String, Future<Map<String, dynamic>?>>{};
    for (final upgrade in upgrades) {
      final name = upgrade['packageName']!;
      final version = upgrade['targetVersion']!;
      final key = '$name@$version';
      pubspecFutures[key] = _pubApi.getVersionPubspec(name, version);
    }

    // Await all results, tolerating individual failures.
    final pubspecs = <String, Map<String, dynamic>>{};
    for (final entry in pubspecFutures.entries) {
      try {
        final result = await entry.value;
        if (result != null) {
          pubspecs[entry.key] = result;
        } else {
          Logger.warn(
            'CascadeResolver: null pubspec for ${entry.key}',
          );
        }
      } catch (e) {
        Logger.warn(
          'CascadeResolver: failed to fetch pubspec for ${entry.key}: $e',
        );
      }
    }

    // Build a map from each upgrade to its dependency constraints.
    final depConstraints = <String, Map<String, String>>{};
    for (final entry in pubspecs.entries) {
      final deps =
          entry.value['dependencies'] as Map<String, dynamic>? ?? {};
      final constraints = <String, String>{};
      for (final dep in deps.entries) {
        final constraint = _extractConstraint(dep.value);
        if (constraint != null) {
          constraints[dep.key] = constraint;
        }
      }
      depConstraints[entry.key] = constraints;
    }

    // 1. Check each upgrade against the current pubspec.
    for (final upgrade in upgrades) {
      final key =
          '${upgrade['packageName']}@${upgrade['targetVersion']}';
      final constraints = depConstraints[key];
      if (constraints == null) continue;

      for (final dep in constraints.entries) {
        final currentDep = currentPubspec.dependencies[dep.key] ??
            currentPubspec.devDependencies[dep.key];
        if (currentDep == null || currentDep.resolvedVersion == null) continue;

        if (!_versionResolver.satisfies(
          currentDep.resolvedVersion!,
          dep.value,
        )) {
          impacts.add(CascadingImpact(
            dependencyName: dep.key,
            requiredBy: key,
            currentConstraint: currentDep.resolvedVersion!,
            conflictReason:
                'Requires ${dep.key} ${dep.value} but current version '
                'is ${currentDep.resolvedVersion}',
          ));
        }
      }
    }

    // 2. Cross-check every pair of upgrades for mutual conflicts.
    final keys = depConstraints.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        final constraintsA = depConstraints[keys[i]]!;
        final constraintsB = depConstraints[keys[j]]!;

        _checkPairwiseConflicts(
          upgradeA: keys[i],
          constraintsA: constraintsA,
          upgradeB: keys[j],
          constraintsB: constraintsB,
          impacts: impacts,
        );
      }
    }

    if (impacts.isNotEmpty) {
      Logger.info(
        'CascadeResolver: found ${impacts.length} cross-upgrade conflict(s)',
      );
    }

    return impacts;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Extract a version constraint string from a pubspec dependency value.
  ///
  /// Dependency values can be:
  /// - A plain string: `"^2.0.0"`
  /// - A map with a `version` key: `{version: ^2.0.0, ...}`
  /// - A hosted/git/path map without version (returns `null`)
  String? _extractConstraint(Object? value) {
    if (value is String) return value;
    if (value is Map) {
      final version = value['version'];
      if (version is String) return version;
    }
    return null;
  }

  /// Check whether two sets of dependency constraints conflict with each
  /// other.
  ///
  /// Two upgrades conflict on dependency D if both require D but their
  /// constraints are incompatible — i.e., there is no single version of D
  /// that satisfies both constraints.
  void _checkPairwiseConflicts({
    required String upgradeA,
    required Map<String, String> constraintsA,
    required String upgradeB,
    required Map<String, String> constraintsB,
    required List<CascadingImpact> impacts,
  }) {
    // Find shared dependencies.
    final sharedDeps =
        constraintsA.keys.where((dep) => constraintsB.containsKey(dep));

    for (final dep in sharedDeps) {
      final constraintA = constraintsA[dep]!;
      final constraintB = constraintsB[dep]!;

      if (!_constraintsOverlap(constraintA, constraintB)) {
        impacts.add(CascadingImpact(
          dependencyName: dep,
          requiredBy: '$upgradeA, $upgradeB',
          currentConstraint: '$constraintA (from $upgradeA)',
          conflictReason:
              '$upgradeA requires $dep $constraintA '
              'but $upgradeB requires $dep $constraintB — '
              'these constraints are incompatible',
        ));
      }
    }
  }

  /// Heuristically check whether two version constraint strings can be
  /// satisfied simultaneously.
  ///
  /// This performs a best-effort check by testing whether one constraint's
  /// implied range overlaps with the other. For complex constraint
  /// expressions this may produce false negatives but will not produce
  /// false positives.
  bool _constraintsOverlap(String constraintA, String constraintB) {
    try {
      final parsedA = _versionResolver.parseConstraint(constraintA);
      final parsedB = _versionResolver.parseConstraint(constraintB);

      // If either constraint allows everything, they overlap.
      if (parsedA.isAny || parsedB.isAny) return true;

      // Try a set of test versions derived from the constraints to see if
      // any version satisfies both.
      final testVersions = _deriveTestVersions(constraintA, constraintB);
      for (final version in testVersions) {
        if (_versionResolver.satisfies(version, constraintA) &&
            _versionResolver.satisfies(version, constraintB)) {
          return true;
        }
      }

      return false;
    } catch (e) {
      // If we can't parse, assume they might overlap to avoid false alarms.
      Logger.debug(
        'CascadeResolver: could not compare constraints '
        '"$constraintA" and "$constraintB": $e',
      );
      return true;
    }
  }

  /// Derive a set of test version strings from two constraint strings.
  ///
  /// Extracts version numbers embedded in the constraints and generates
  /// nearby versions to test for overlap.
  List<String> _deriveTestVersions(String constraintA, String constraintB) {
    final versionPattern = RegExp(r'(\d+)\.(\d+)\.(\d+)');
    final versions = <String>{};

    for (final constraint in [constraintA, constraintB]) {
      for (final match in versionPattern.allMatches(constraint)) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        final patch = int.parse(match.group(3)!);

        // Add the exact version and some neighbors.
        versions.add('$major.$minor.$patch');
        if (patch > 0) versions.add('$major.$minor.${patch - 1}');
        versions.add('$major.$minor.${patch + 1}');
        if (minor > 0) versions.add('$major.${minor - 1}.0');
        versions.add('$major.${minor + 1}.0');
        if (major > 0) versions.add('${major - 1}.0.0');
        versions.add('${major + 1}.0.0');
      }
    }

    return versions.toList();
  }
}
