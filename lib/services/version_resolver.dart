import 'package:pub_semver/pub_semver.dart';

class VersionResolver {
  /// Parse a version string into a Version object.
  Version parseVersion(String versionStr) {
    return Version.parse(versionStr);
  }

  /// Parse a version constraint string.
  VersionConstraint parseConstraint(String constraintStr) {
    return VersionConstraint.parse(constraintStr);
  }

  /// Check if a version satisfies a constraint.
  bool satisfies(String version, String constraint) {
    try {
      return VersionConstraint.parse(constraint)
          .allows(Version.parse(version));
    } catch (_) {
      return false;
    }
  }

  /// Get all versions from a list that fall between two versions
  /// (exclusive of [fromVersion], inclusive of [toVersion]).
  ///
  /// The returned list is sorted in ascending order.
  List<String> getVersionsInRange(
    List<String> allVersions,
    String fromVersion,
    String toVersion,
  ) {
    final from = Version.parse(fromVersion);
    final to = Version.parse(toVersion);

    return allVersions.where((v) {
      try {
        final ver = Version.parse(v);
        return ver > from && ver <= to;
      } catch (_) {
        return false;
      }
    }).toList()
      ..sort((a, b) => Version.parse(a).compareTo(Version.parse(b)));
  }

  /// Check if upgrading from one version to another is a major bump.
  bool isMajorBump(String from, String to) {
    final fromVer = Version.parse(from);
    final toVer = Version.parse(to);
    return toVer.major > fromVer.major;
  }

  /// Check if upgrading is a minor bump (same major, higher minor).
  bool isMinorBump(String from, String to) {
    final fromVer = Version.parse(from);
    final toVer = Version.parse(to);
    return toVer.major == fromVer.major && toVer.minor > fromVer.minor;
  }

  /// Check if a version is a prerelease.
  bool isPrerelease(String version) {
    return Version.parse(version).isPreRelease;
  }

  /// Get the latest non-prerelease version from a list.
  ///
  /// Returns `null` if no stable versions are found.
  String? getLatestStable(List<String> versions) {
    final stable = versions.where((v) {
      try {
        return !Version.parse(v).isPreRelease;
      } catch (_) {
        return false;
      }
    }).toList()
      ..sort((a, b) => Version.parse(a).compareTo(Version.parse(b)));
    return stable.isEmpty ? null : stable.last;
  }

  /// Check if a target version would satisfy the given constraint.
  ///
  /// Useful for checking if a pubspec.yaml constraint needs updating.
  bool constraintAllows(String constraint, String version) {
    try {
      return VersionConstraint.parse(constraint)
          .allows(Version.parse(version));
    } catch (_) {
      return false;
    }
  }

  /// Generate a new caret constraint string for a target version.
  ///
  /// For example, for version `"6.1.0"` this returns `"^6.1.0"`.
  String suggestConstraint(String targetVersion) {
    final ver = Version.parse(targetVersion);
    return '^${ver.major}.${ver.minor}.${ver.patch}';
  }

  /// Compare two versions.
  ///
  /// Returns a negative value if [a] < [b], zero if equal, and a positive
  /// value if [a] > [b].
  int compareVersions(String a, String b) {
    return Version.parse(a).compareTo(Version.parse(b));
  }

  /// Filter versions, excluding prereleases unless [includePrerelease] is set.
  List<String> filterVersions(
    List<String> versions, {
    bool includePrerelease = false,
  }) {
    if (includePrerelease) return versions;
    return versions.where((v) {
      try {
        return !Version.parse(v).isPreRelease;
      } catch (_) {
        return false;
      }
    }).toList();
  }
}
