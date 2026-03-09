import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:augur/services/codebase_analyzer.dart';

void main() {
  late CodebaseAnalyzer analyzer;
  late String fixturesPath;
  late String sampleDartFilesPath;

  setUp(() {
    analyzer = CodebaseAnalyzer();
    fixturesPath = p.join(p.current, 'test', 'fixtures');
    sampleDartFilesPath = p.join(fixturesPath, 'sample_dart_files');
  });

  group('CodebaseAnalyzer', () {
    group('findDartFiles', () {
      test('finds all .dart files in sample directory', () async {
        final files = await analyzer.findDartFiles(sampleDartFilesPath);
        // The fixture has 3 dart files: provider_usage, bloc_usage, riverpod_usage
        expect(files.length, 3);
        expect(
            files.any((f) => f.endsWith('provider_usage.dart')), isTrue);
        expect(files.any((f) => f.endsWith('bloc_usage.dart')), isTrue);
        expect(
            files.any((f) => f.endsWith('riverpod_usage.dart')), isTrue);
      });

      test('excludes generated files (.g.dart, .freezed.dart)', () async {
        final files = await analyzer.findDartFiles(sampleDartFilesPath);
        expect(files.any((f) => f.endsWith('.g.dart')), isFalse);
        expect(files.any((f) => f.endsWith('.freezed.dart')), isFalse);
        expect(files.any((f) => f.endsWith('.mocks.dart')), isFalse);
      });

      test('returns empty list for nonexistent directory', () async {
        final files =
            await analyzer.findDartFiles('/nonexistent/directory');
        expect(files, isEmpty);
      });

      test('returns absolute normalized paths', () async {
        final files = await analyzer.findDartFiles(sampleDartFilesPath);
        for (final file in files) {
          expect(p.isAbsolute(file), isTrue);
          expect(file, equals(p.normalize(file)));
        }
      });
    });

    group('findFilesImporting', () {
      test('finds files importing provider package', () async {
        final files = await analyzer.findFilesImporting(
            sampleDartFilesPath, 'provider');
        expect(files.any((f) => f.endsWith('provider_usage.dart')), isTrue);
      });

      test('finds files importing flutter_bloc', () async {
        final files = await analyzer.findFilesImporting(
            sampleDartFilesPath, 'flutter_bloc');
        expect(files.any((f) => f.endsWith('bloc_usage.dart')), isTrue);
        // provider_usage.dart should not match flutter_bloc
        expect(
            files.any((f) => f.endsWith('provider_usage.dart')), isFalse);
      });

      test('finds files importing flutter_riverpod', () async {
        final files = await analyzer.findFilesImporting(
            sampleDartFilesPath, 'flutter_riverpod');
        expect(
            files.any((f) => f.endsWith('riverpod_usage.dart')), isTrue);
      });

      test('returns empty for package not imported by any file', () async {
        final files = await analyzer.findFilesImporting(
            sampleDartFilesPath, 'nonexistent_package');
        expect(files, isEmpty);
      });
    });

    group('countImportingFiles', () {
      test('counts files importing flutter_bloc', () async {
        final count = await analyzer.countImportingFiles(
            sampleDartFilesPath, 'flutter_bloc');
        expect(count, 1);
      });

      test('counts files importing provider', () async {
        final count = await analyzer.countImportingFiles(
            sampleDartFilesPath, 'provider');
        expect(count, 1);
      });

      test('returns zero for unimported package', () async {
        final count = await analyzer.countImportingFiles(
            sampleDartFilesPath, 'no_such_package');
        expect(count, 0);
      });
    });

    group('getImportSummary', () {
      test('shows import paths for provider', () async {
        final summary = await analyzer.getImportSummary(
            sampleDartFilesPath, 'provider');
        expect(summary, isNotEmpty);
        expect(
          summary.keys
              .any((k) => k.contains('package:provider')),
          isTrue,
        );
      });

      test('shows import paths for flutter_bloc', () async {
        final summary = await analyzer.getImportSummary(
            sampleDartFilesPath, 'flutter_bloc');
        expect(summary, isNotEmpty);
        expect(
          summary.keys.any(
              (k) => k.contains('package:flutter_bloc')),
          isTrue,
        );
      });

      test('maps import URIs to file paths', () async {
        final summary = await analyzer.getImportSummary(
            sampleDartFilesPath, 'provider');
        for (final entry in summary.entries) {
          expect(entry.key, startsWith('package:provider'));
          expect(entry.value, isNotEmpty);
          for (final filePath in entry.value) {
            expect(filePath.endsWith('.dart'), isTrue);
          }
        }
      });

      test('returns empty map for unimported package', () async {
        final summary = await analyzer.getImportSummary(
            sampleDartFilesPath, 'nonexistent_package');
        expect(summary, isEmpty);
      });
    });

    group('maxFiles limit', () {
      test('respects maxFiles constructor parameter', () async {
        final limitedAnalyzer = CodebaseAnalyzer(maxFiles: 1);
        final files =
            await limitedAnalyzer.findDartFiles(sampleDartFilesPath);
        expect(files.length, 1);
      });

      test('default maxFiles allows all fixture files', () async {
        final files = await analyzer.findDartFiles(sampleDartFilesPath);
        expect(files.length, 3);
      });
    });
  });
}
