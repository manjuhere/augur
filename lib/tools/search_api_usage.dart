import '../services/codebase_analyzer.dart';
import '../utils/logger.dart';

class SearchApiUsageTool {

  SearchApiUsageTool(this._analyzer);
  final CodebaseAnalyzer _analyzer;

  /// Execute the search_api_usage tool
  /// Input: projectPath, apis (list of strings), packageFilter?
  /// Output: per-API match results with files, lines, types
  Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final projectPath = args['projectPath'] as String;
    final apis = (args['apis'] as List).cast<String>();
    final packageFilter = args['packageFilter'] as String?;

    Logger.info('Searching for ${apis.length} API(s) in $projectPath');

    final results = await _analyzer.searchApiUsages(
      projectPath: projectPath,
      apis: apis,
      packageFilter: packageFilter,
    );

    return {
      'searchedApis': apis,
      'packageFilter': packageFilter,
      'results': results.map((r) => r.toJson()).toList(),
      'totalMatches': results.fold<int>(0, (sum, r) => sum + r.totalMatches),
    };
  }
}
