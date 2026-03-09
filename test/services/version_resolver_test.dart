import 'package:test/test.dart';
import 'package:augur/services/version_resolver.dart';

void main() {
  late VersionResolver resolver;

  setUp(() {
    resolver = VersionResolver();
  });

  group('VersionResolver', () {
    group('isMajorBump', () {
      test('detects major version changes', () {
        expect(resolver.isMajorBump('1.0.0', '2.0.0'), isTrue);
        expect(resolver.isMajorBump('1.9.9', '2.0.0'), isTrue);
        expect(resolver.isMajorBump('0.9.0', '1.0.0'), isTrue);
      });

      test('returns false for non-major changes', () {
        expect(resolver.isMajorBump('1.0.0', '1.1.0'), isFalse);
        expect(resolver.isMajorBump('1.0.0', '1.0.1'), isFalse);
        expect(resolver.isMajorBump('2.0.0', '2.0.0'), isFalse);
      });
    });

    group('isMinorBump', () {
      test('detects minor version changes', () {
        expect(resolver.isMinorBump('1.0.0', '1.1.0'), isTrue);
        expect(resolver.isMinorBump('1.0.0', '1.5.0'), isTrue);
        expect(resolver.isMinorBump('2.3.0', '2.4.0'), isTrue);
      });

      test('returns false for major bumps', () {
        expect(resolver.isMinorBump('1.0.0', '2.0.0'), isFalse);
      });

      test('returns false for patch bumps', () {
        expect(resolver.isMinorBump('1.0.0', '1.0.1'), isFalse);
      });

      test('returns false for same version', () {
        expect(resolver.isMinorBump('1.1.0', '1.1.0'), isFalse);
      });
    });

    group('satisfies', () {
      test('caret constraint allows matching versions', () {
        expect(resolver.satisfies('6.0.5', '^6.0.0'), isTrue);
        expect(resolver.satisfies('6.9.9', '^6.0.0'), isTrue);
      });

      test('caret constraint rejects major version bump', () {
        expect(resolver.satisfies('7.0.0', '^6.0.0'), isFalse);
      });

      test('range constraint works correctly', () {
        expect(resolver.satisfies('6.1.0', '>=6.0.0 <7.0.0'), isTrue);
        expect(resolver.satisfies('5.9.0', '>=6.0.0 <7.0.0'), isFalse);
        expect(resolver.satisfies('7.0.0', '>=6.0.0 <7.0.0'), isFalse);
      });

      test('exact version match', () {
        expect(resolver.satisfies('1.0.0', '1.0.0'), isTrue);
        expect(resolver.satisfies('1.0.1', '1.0.0'), isFalse);
      });

      test('returns false for invalid constraint', () {
        expect(resolver.satisfies('1.0.0', 'not_a_constraint'), isFalse);
      });
    });

    group('getLatestStable', () {
      test('returns latest non-prerelease', () {
        final versions = ['1.0.0', '2.0.0-beta', '1.5.0', '2.0.0'];
        expect(resolver.getLatestStable(versions), '2.0.0');
      });

      test('skips all prereleases', () {
        final versions = ['1.0.0', '2.0.0-alpha', '2.0.0-beta'];
        expect(resolver.getLatestStable(versions), '1.0.0');
      });

      test('returns null when all versions are prereleases', () {
        final versions = ['1.0.0-alpha', '2.0.0-beta', '3.0.0-rc.1'];
        expect(resolver.getLatestStable(versions), isNull);
      });

      test('returns null for empty list', () {
        expect(resolver.getLatestStable([]), isNull);
      });

      test('works with single stable version', () {
        expect(resolver.getLatestStable(['1.0.0']), '1.0.0');
      });
    });

    group('getVersionsInRange', () {
      test('returns versions between bounds (exclusive from, inclusive to)',
          () {
        final versions = ['1.0.0', '1.1.0', '1.2.0', '2.0.0', '2.1.0'];
        final range =
            resolver.getVersionsInRange(versions, '1.0.0', '2.0.0');
        expect(range, ['1.1.0', '1.2.0', '2.0.0']);
      });

      test('excludes the from version', () {
        final versions = ['1.0.0', '1.1.0', '2.0.0'];
        final range =
            resolver.getVersionsInRange(versions, '1.0.0', '2.0.0');
        expect(range, isNot(contains('1.0.0')));
      });

      test('includes the to version', () {
        final versions = ['1.0.0', '1.1.0', '2.0.0'];
        final range =
            resolver.getVersionsInRange(versions, '1.0.0', '2.0.0');
        expect(range, contains('2.0.0'));
      });

      test('returns empty when no versions in range', () {
        final versions = ['1.0.0', '3.0.0'];
        final range =
            resolver.getVersionsInRange(versions, '1.0.0', '2.0.0');
        expect(range, isEmpty);
      });

      test('returns results sorted in ascending order', () {
        final versions = ['2.0.0', '1.1.0', '1.5.0', '1.2.0'];
        final range =
            resolver.getVersionsInRange(versions, '1.0.0', '2.0.0');
        expect(range, ['1.1.0', '1.2.0', '1.5.0', '2.0.0']);
      });
    });

    group('isPrerelease', () {
      test('detects alpha prereleases', () {
        expect(resolver.isPrerelease('1.0.0-alpha'), isTrue);
      });

      test('detects beta prereleases', () {
        expect(resolver.isPrerelease('1.0.0-beta'), isTrue);
      });

      test('detects rc prereleases', () {
        expect(resolver.isPrerelease('1.0.0-rc.1'), isTrue);
      });

      test('detects dev prereleases', () {
        expect(resolver.isPrerelease('1.0.0-dev.5'), isTrue);
      });

      test('stable versions are not prerelease', () {
        expect(resolver.isPrerelease('1.0.0'), isFalse);
        expect(resolver.isPrerelease('0.1.0'), isFalse);
        expect(resolver.isPrerelease('10.20.30'), isFalse);
      });
    });

    group('suggestConstraint', () {
      test('generates caret constraint for stable version', () {
        expect(resolver.suggestConstraint('6.1.0'), '^6.1.0');
      });

      test('generates caret constraint for zero major version', () {
        expect(resolver.suggestConstraint('0.5.0'), '^0.5.0');
      });

      test('generates caret constraint for patch version', () {
        expect(resolver.suggestConstraint('1.2.3'), '^1.2.3');
      });
    });

    group('compareVersions', () {
      test('a < b returns negative', () {
        expect(resolver.compareVersions('1.0.0', '2.0.0'), isNegative);
        expect(resolver.compareVersions('1.0.0', '1.1.0'), isNegative);
        expect(resolver.compareVersions('1.0.0', '1.0.1'), isNegative);
      });

      test('a > b returns positive', () {
        expect(resolver.compareVersions('2.0.0', '1.0.0'), isPositive);
        expect(resolver.compareVersions('1.1.0', '1.0.0'), isPositive);
        expect(resolver.compareVersions('1.0.1', '1.0.0'), isPositive);
      });

      test('a == b returns zero', () {
        expect(resolver.compareVersions('1.0.0', '1.0.0'), isZero);
        expect(resolver.compareVersions('3.5.2', '3.5.2'), isZero);
      });
    });

    group('filterVersions', () {
      test('excludes prereleases by default', () {
        final versions = ['1.0.0', '2.0.0-beta', '2.0.0'];
        expect(resolver.filterVersions(versions), ['1.0.0', '2.0.0']);
      });

      test('includes prereleases when requested', () {
        final versions = ['1.0.0', '2.0.0-beta', '2.0.0'];
        expect(
          resolver.filterVersions(versions, includePrerelease: true),
          versions,
        );
      });

      test('returns empty list when all are prereleases', () {
        final versions = ['1.0.0-alpha', '2.0.0-beta'];
        expect(resolver.filterVersions(versions), isEmpty);
      });

      test('returns all when none are prereleases', () {
        final versions = ['1.0.0', '1.1.0', '2.0.0'];
        expect(resolver.filterVersions(versions), versions);
      });
    });

    group('parseVersion', () {
      test('parses valid version string', () {
        final version = resolver.parseVersion('1.2.3');
        expect(version.major, 1);
        expect(version.minor, 2);
        expect(version.patch, 3);
      });

      test('parses prerelease version', () {
        final version = resolver.parseVersion('1.0.0-alpha');
        expect(version.isPreRelease, isTrue);
      });

      test('throws on invalid version', () {
        expect(() => resolver.parseVersion('not.a.version'), throwsFormatException);
      });
    });

    group('parseConstraint', () {
      test('parses caret constraint', () {
        final constraint = resolver.parseConstraint('^1.0.0');
        expect(constraint, isNotNull);
      });

      test('parses range constraint', () {
        final constraint = resolver.parseConstraint('>=1.0.0 <2.0.0');
        expect(constraint, isNotNull);
      });
    });

    group('constraintAllows', () {
      test('returns true when version matches constraint', () {
        expect(resolver.constraintAllows('^6.0.0', '6.5.0'), isTrue);
      });

      test('returns false when version does not match constraint', () {
        expect(resolver.constraintAllows('^6.0.0', '7.0.0'), isFalse);
      });

      test('returns false for invalid constraint', () {
        expect(resolver.constraintAllows('invalid', '1.0.0'), isFalse);
      });
    });
  });
}
