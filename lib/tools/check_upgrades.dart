import '../models/pubspec_data.dart';
import '../services/pubspec_parser.dart';
import '../services/pub_api_client.dart';
import '../services/version_resolver.dart';
import '../utils/logger.dart';

class CheckUpgradesTool {

  CheckUpgradesTool(this._parser, this._pubApi, this._versionResolver);
  final PubspecParser _parser;
  final PubApiClient _pubApi;
  final VersionResolver _versionResolver;

  /// Execute check_available_upgrades
  /// Input: projectPath, packageName?, includePrerelease?, targetFlutterVersion?
  /// Output: per-dependency upgrade info
  Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final projectPath = args['projectPath'] as String;
    final specificPackage = args['packageName'] as String?;
    final includePrerelease = args['includePrerelease'] as bool? ?? false;
    final pubspec = await _parser.parse(projectPath);

    // Determine which packages to check
    Map<String, DependencyInfo> packagesToCheck;
    if (specificPackage != null) {
      final dep = pubspec.dependencies[specificPackage] ??
          pubspec.devDependencies[specificPackage];
      if (dep == null) {
        throw ArgumentError(
            'Package $specificPackage not found in pubspec.yaml');
      }
      packagesToCheck = {specificPackage: dep};
    } else {
      packagesToCheck = {...pubspec.dependencies, ...pubspec.devDependencies};
    }

    // Only check hosted packages (skip path, git, sdk dependencies)
    packagesToCheck.removeWhere((_, dep) => dep.source != 'hosted');

    final upgrades = <Map<String, dynamic>>[];

    for (final entry in packagesToCheck.entries) {
      try {
        final info = await _checkPackageUpgrade(
          entry.key,
          entry.value,
          includePrerelease: includePrerelease,
        );
        if (info != null) upgrades.add(info);
      } catch (e) {
        Logger.warn('Failed to check upgrades for ${entry.key}: $e');
        upgrades.add({
          'packageName': entry.key,
          'error': e.toString(),
        });
      }
    }

    return {
      'projectName': pubspec.name,
      'packagesChecked': packagesToCheck.length,
      'upgradesAvailable':
          upgrades.where((u) => u.containsKey('latestVersion')).length,
      'upgrades': upgrades,
    };
  }

  Future<Map<String, dynamic>?> _checkPackageUpgrade(
    String name,
    DependencyInfo dep, {
    bool includePrerelease = false,
  }) async {
    final versions = await _pubApi.getVersions(name);
    final filtered = _versionResolver.filterVersions(versions,
        includePrerelease: includePrerelease);
    final latest = _versionResolver.getLatestStable(filtered);

    if (latest == null || dep.resolvedVersion == null) return null;

    final currentVersion = dep.resolvedVersion!;
    if (_versionResolver.compareVersions(currentVersion, latest) >= 0) {
      return {
        'packageName': name,
        'currentVersion': currentVersion,
        'latestVersion': latest,
        'isUpToDate': true,
        'isDev': dep.isDev,
      };
    }

    // Check for retracted versions
    final isLatestRetracted = await _pubApi.isVersionRetracted(name, latest);

    return {
      'packageName': name,
      'currentVersion': currentVersion,
      'latestVersion': latest,
      'isUpToDate': false,
      'isMajorUpgrade': _versionResolver.isMajorBump(currentVersion, latest),
      'isMinorUpgrade': _versionResolver.isMinorBump(currentVersion, latest),
      'isRetracted': isLatestRetracted,
      'constraintAllowsUpgrade': dep.versionConstraint != null
          ? _versionResolver.constraintAllows(dep.versionConstraint!, latest)
          : null,
      'suggestedConstraint': _versionResolver.suggestConstraint(latest),
      'isDev': dep.isDev,
      'currentConstraint': dep.versionConstraint,
    };
  }
}
