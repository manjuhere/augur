import '../services/pubspec_parser.dart';
import '../utils/logger.dart';

class ScanProjectTool {

  ScanProjectTool(this._parser);
  final PubspecParser _parser;

  /// Execute the scan_project tool
  /// Input: projectPath, includeDevDependencies?, includeTransitive?
  /// Output: project name, SDK constraints, dependency list with versions
  Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final projectPath = args['projectPath'] as String;
    final includeDevDeps = args['includeDevDependencies'] as bool? ?? true;
    final includeTransitive = args['includeTransitive'] as bool? ?? false;

    Logger.info('Scanning project at $projectPath');

    final pubspec = await _parser.parse(
      projectPath,
      includeDevDependencies: includeDevDeps,
      includeTransitive: includeTransitive,
    );

    return {
      'projectName': pubspec.name,
      'version': pubspec.version,
      'description': pubspec.description,
      'sdkConstraints': pubspec.sdkConstraints.toJson(),
      'dependencyCount': pubspec.dependencies.length,
      'devDependencyCount': pubspec.devDependencies.length,
      'dependencies': pubspec.dependencies.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
      'devDependencies': pubspec.devDependencies.map(
        (k, v) => MapEntry(k, v.toJson()),
      ),
    };
  }
}
