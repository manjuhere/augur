/// Models for API usage search results.

class ApiUsageResult {
  const ApiUsageResult({
    required this.api,
    this.packageFilter,
    required this.totalMatches,
    required this.matches,
  });

  final String api;
  final String? packageFilter;
  final int totalMatches;
  final List<ApiMatch> matches;

  Map<String, dynamic> toJson() => {
        'api': api,
        if (packageFilter != null) 'packageFilter': packageFilter,
        'totalMatches': totalMatches,
        'matches': matches.map((e) => e.toJson()).toList(),
      };
}

class ApiMatch {
  const ApiMatch({
    required this.filePath,
    required this.line,
    required this.column,
    required this.lineContent,
    this.resolvedType,
    this.enclosingClass,
    this.enclosingMethod,
    this.importSource,
  });

  final String filePath;
  final int line;
  final int column;
  final String lineContent;
  final String? resolvedType;
  final String? enclosingClass;
  final String? enclosingMethod;
  final String? importSource;

  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'line': line,
        'column': column,
        'lineContent': lineContent,
        if (resolvedType != null) 'resolvedType': resolvedType,
        if (enclosingClass != null) 'enclosingClass': enclosingClass,
        if (enclosingMethod != null) 'enclosingMethod': enclosingMethod,
        if (importSource != null) 'importSource': importSource,
      };
}
