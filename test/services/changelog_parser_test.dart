import 'dart:io';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:augur/services/changelog_parser.dart';

void main() {
  late ChangelogParser parser;
  late String sampleChangelog;

  setUp(() async {
    parser = ChangelogParser();
    sampleChangelog = await File(
      p.join(p.current, 'test', 'fixtures', 'sample_changelog.md'),
    ).readAsString();
  });

  group('ChangelogParser', () {
    group('parse', () {
      test('parses all version entries from fixture', () {
        final entries = parser.parse(sampleChangelog);
        // The fixture has 4 versions: 7.0.0, 6.1.0, 6.0.5, 6.0.0
        expect(entries.length, 4);
        expect(entries.map((e) => e.version),
            containsAll(['7.0.0', '6.1.0', '6.0.5', '6.0.0']));
      });

      test('entries are ordered newest first', () {
        final entries = parser.parse(sampleChangelog);
        expect(entries[0].version, '7.0.0');
        expect(entries[1].version, '6.1.0');
        expect(entries[2].version, '6.0.5');
        expect(entries[3].version, '6.0.0');
      });

      test('detects breaking changes in version 7.0.0', () {
        final entries = parser.parse(sampleChangelog);
        final v7 = entries.firstWhere((e) => e.version == '7.0.0');
        expect(v7.hasBreakingChanges, isTrue);
        expect(v7.breakingChanges, isNotEmpty);
      });

      test('version 6.1.0 has no breaking changes', () {
        final entries = parser.parse(sampleChangelog);
        final v61 = entries.firstWhere((e) => e.version == '6.1.0');
        expect(v61.hasBreakingChanges, isFalse);
        expect(v61.breakingChanges, isEmpty);
      });

      test('version 6.0.5 has no breaking changes', () {
        final entries = parser.parse(sampleChangelog);
        final v605 = entries.firstWhere((e) => e.version == '6.0.5');
        expect(v605.hasBreakingChanges, isFalse);
        expect(v605.breakingChanges, isEmpty);
      });

      test('detects breaking changes in version 6.0.0', () {
        final entries = parser.parse(sampleChangelog);
        final v6 = entries.firstWhere((e) => e.version == '6.0.0');
        expect(v6.hasBreakingChanges, isTrue);
        expect(v6.breakingChanges, isNotEmpty);
      });

      test('breaking changes have severity assigned', () {
        final entries = parser.parse(sampleChangelog);
        final v7 = entries.firstWhere((e) => e.version == '7.0.0');
        for (final bc in v7.breakingChanges) {
          expect(bc.severity, isNotNull);
        }
      });

      test('breaking changes have category assigned', () {
        final entries = parser.parse(sampleChangelog);
        final v7 = entries.firstWhere((e) => e.version == '7.0.0');
        for (final bc in v7.breakingChanges) {
          expect(bc.category, isNotNull);
        }
      });

      test('breaking changes have unique ids', () {
        final entries = parser.parse(sampleChangelog);
        final v7 = entries.firstWhere((e) => e.version == '7.0.0');
        final ids = v7.breakingChanges.map((bc) => bc.id).toSet();
        expect(ids.length, v7.breakingChanges.length);
      });

      test('parses change lines as bullet items', () {
        final entries = parser.parse(sampleChangelog);
        final v7 = entries.firstWhere((e) => e.version == '7.0.0');
        expect(v7.changes, isNotEmpty);
      });

      test('v6.1.0 has expected change items', () {
        final entries = parser.parse(sampleChangelog);
        final v61 = entries.firstWhere((e) => e.version == '6.1.0');
        expect(v61.changes, isNotEmpty);
        // Should contain new features and bug fixes
        expect(
          v61.changes.any((c) => c.contains('deprecation warning')),
          isTrue,
        );
      });

      test('content field contains the raw section text', () {
        final entries = parser.parse(sampleChangelog);
        final v7 = entries.firstWhere((e) => e.version == '7.0.0');
        expect(v7.content, contains('BREAKING'));
        expect(v7.content, contains('Provider.of'));
      });
    });

    group('getEntriesBetween', () {
      test('filters correctly between 6.0.5 and 7.0.0', () {
        final entries = parser.parse(sampleChangelog);
        final between = parser.getEntriesBetween(entries, '6.0.5', '7.0.0');
        final versions = between.map((e) => e.version).toList();
        // Should include 7.0.0 and 6.1.0 (exclusive of 6.0.5, inclusive of 7.0.0)
        expect(versions, contains('7.0.0'));
        expect(versions, contains('6.1.0'));
        expect(versions, isNot(contains('6.0.5')));
        expect(versions, isNot(contains('6.0.0')));
      });

      test('filters correctly between 6.0.0 and 6.0.5', () {
        final entries = parser.parse(sampleChangelog);
        final between = parser.getEntriesBetween(entries, '6.0.0', '6.0.5');
        final versions = between.map((e) => e.version).toList();
        expect(versions, contains('6.0.5'));
        expect(versions, isNot(contains('6.0.0')));
        expect(versions, isNot(contains('6.1.0')));
      });

      test('returns empty when from equals to', () {
        final entries = parser.parse(sampleChangelog);
        final between = parser.getEntriesBetween(entries, '6.0.5', '6.0.5');
        expect(between, isEmpty);
      });

      test('returns empty for empty entries list', () {
        final between = parser.getEntriesBetween([], '1.0.0', '2.0.0');
        expect(between, isEmpty);
      });

      test('returns all entries between 6.0.0 and 7.0.0', () {
        final entries = parser.parse(sampleChangelog);
        final between = parser.getEntriesBetween(entries, '6.0.0', '7.0.0');
        final versions = between.map((e) => e.version).toList();
        expect(versions, contains('7.0.0'));
        expect(versions, contains('6.1.0'));
        expect(versions, contains('6.0.5'));
        expect(versions, isNot(contains('6.0.0')));
      });
    });

    group('edge cases', () {
      test('handles empty changelog', () {
        final entries = parser.parse('');
        expect(entries, isEmpty);
      });

      test('handles changelog with no version headings', () {
        final entries = parser.parse('Just some text without versions');
        expect(entries, isEmpty);
      });

      test('handles changelog with only whitespace', () {
        final entries = parser.parse('   \n\n   \n  ');
        expect(entries, isEmpty);
      });

      test('handles version with bracketed format', () {
        const content = '''
## [2.0.0] - 2024-01-15

### BREAKING CHANGES
- Removed legacy API

## [1.0.0] - 2023-06-01

- Initial release
''';
        final entries = parser.parse(content);
        expect(entries.length, 2);
        expect(entries[0].version, '2.0.0');
        expect(entries[0].date, '2024-01-15');
        expect(entries[1].version, '1.0.0');
        expect(entries[1].date, '2023-06-01');
      });

      test('handles version with v prefix', () {
        const content = '''
## v3.0.0

- Some change
''';
        final entries = parser.parse(content);
        expect(entries.length, 1);
        expect(entries[0].version, '3.0.0');
      });

      test('handles prerelease versions', () {
        const content = '''
## 2.0.0-beta.1

- Beta feature

## 1.0.0

- Stable release
''';
        final entries = parser.parse(content);
        expect(entries.length, 2);
        expect(entries[0].version, '2.0.0-beta.1');
      });
    });

    group('ChangelogEntry.toJson', () {
      test('produces valid JSON map', () {
        final entries = parser.parse(sampleChangelog);
        final json = entries.first.toJson();
        expect(json['version'], isA<String>());
        expect(json['hasBreakingChanges'], isA<bool>());
        expect(json['breakingChanges'], isA<List>());
        expect(json['changes'], isA<List>());
      });
    });
  });
}
