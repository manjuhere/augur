import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:augur/services/pubspec_parser.dart';

void main() {
  late PubspecParser parser;
  late String fixturesPath;

  setUp(() {
    parser = PubspecParser();
    fixturesPath = p.join(p.current, 'test', 'fixtures');
  });

  group('PubspecParser', () {
    test('parses project name and version', () async {
      final result = await parser.parse(fixturesPath);
      expect(result.name, 'sample_flutter_app');
      expect(result.version, '1.0.0+1');
    });

    test('parses description', () async {
      final result = await parser.parse(fixturesPath);
      expect(result.description,
          'A sample Flutter application for testing upgrade analysis.');
    });

    test('parses SDK constraints', () async {
      final result = await parser.parse(fixturesPath);
      expect(result.sdkConstraints.dartSdk, '>=3.0.0 <4.0.0');
      expect(result.sdkConstraints.flutterSdk, '>=3.10.0');
    });

    test('parses all direct dependencies', () async {
      final result = await parser.parse(fixturesPath);
      // The fixture pubspec.yaml has 10 direct dependencies:
      // flutter, provider, http, go_router, flutter_bloc, riverpod,
      // freezed_annotation, json_annotation, shared_preferences, dio
      expect(result.dependencies.containsKey('provider'), isTrue);
      expect(result.dependencies.containsKey('http'), isTrue);
      expect(result.dependencies.containsKey('go_router'), isTrue);
      expect(result.dependencies.containsKey('flutter_bloc'), isTrue);
      expect(result.dependencies.containsKey('riverpod'), isTrue);
      expect(result.dependencies.containsKey('freezed_annotation'), isTrue);
      expect(result.dependencies.containsKey('json_annotation'), isTrue);
      expect(result.dependencies.containsKey('shared_preferences'), isTrue);
      expect(result.dependencies.containsKey('dio'), isTrue);
      expect(result.dependencies.containsKey('flutter'), isTrue);
      expect(result.dependencies.length, 10);
    });

    test('parses version constraints correctly', () async {
      final result = await parser.parse(fixturesPath);
      expect(result.dependencies['provider']?.versionConstraint, '^6.0.5');
      expect(result.dependencies['http']?.versionConstraint, '^1.1.0');
      expect(result.dependencies['go_router']?.versionConstraint, '^12.0.0');
    });

    test('parses dependency sources correctly', () async {
      final result = await parser.parse(fixturesPath);
      // provider is a hosted dependency
      expect(result.dependencies['provider']?.source, 'hosted');
      // flutter is an SDK dependency
      expect(result.dependencies['flutter']?.source, 'sdk');
    });

    test('parses dev dependencies', () async {
      final result = await parser.parse(fixturesPath);
      expect(result.devDependencies.containsKey('build_runner'), isTrue);
      expect(result.devDependencies.containsKey('mockito'), isTrue);
      expect(result.devDependencies.containsKey('flutter_test'), isTrue);
      expect(result.devDependencies.containsKey('flutter_lints'), isTrue);
      expect(result.devDependencies.containsKey('freezed'), isTrue);
      expect(result.devDependencies.containsKey('json_serializable'), isTrue);
    });

    test('excludes dev deps when includeDevDependencies=false', () async {
      final result =
          await parser.parse(fixturesPath, includeDevDependencies: false);
      expect(result.devDependencies, isEmpty);
    });

    test('merges resolved versions from lock file', () async {
      final result = await parser.parse(fixturesPath);
      expect(result.dependencies['provider']?.resolvedVersion, '6.0.5');
      expect(result.dependencies['http']?.resolvedVersion, '1.1.0');
      expect(result.dependencies['go_router']?.resolvedVersion, '12.0.0');
      expect(result.dependencies['flutter_bloc']?.resolvedVersion, '8.1.3');
      expect(result.dependencies['riverpod']?.resolvedVersion, '2.4.0');
      expect(result.dependencies['dio']?.resolvedVersion, '5.3.0');
    });

    test('includes transitive deps when requested', () async {
      final result =
          await parser.parse(fixturesPath, includeTransitive: true);
      // collection and meta are transitive in our fixture lock file
      final allDeps = {...result.dependencies, ...result.devDependencies};
      final transitiveDeps =
          allDeps.values.where((d) => d.isTransitive).toList();
      expect(transitiveDeps, isNotEmpty);
      expect(
        transitiveDeps.map((d) => d.name),
        containsAll(['collection', 'meta']),
      );
    });

    test('transitive deps have resolved versions from lock file', () async {
      final result =
          await parser.parse(fixturesPath, includeTransitive: true);
      final allDeps = {...result.dependencies, ...result.devDependencies};
      final collection = allDeps['collection'];
      expect(collection, isNotNull);
      expect(collection!.resolvedVersion, '1.18.0');
      expect(collection.isTransitive, isTrue);
    });

    test('does not include transitive deps by default', () async {
      final result = await parser.parse(fixturesPath);
      final allDeps = {...result.dependencies, ...result.devDependencies};
      expect(allDeps.containsKey('collection'), isFalse);
      expect(allDeps.containsKey('meta'), isFalse);
    });

    test('throws on missing pubspec.yaml', () async {
      expect(
        () => parser.parse('/nonexistent/path'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('PubspecData.toJson produces valid map', () async {
      final result = await parser.parse(fixturesPath);
      final json = result.toJson();
      expect(json['name'], 'sample_flutter_app');
      expect(json['version'], '1.0.0+1');
      expect(json['sdkConstraints'], isA<Map>());
      expect(json['dependencies'], isA<Map>());
      expect(json['devDependencies'], isA<Map>());
    });
  });
}
