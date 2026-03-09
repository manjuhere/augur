/// AST-based Dart code analyzer for finding API usages semantically.
///
/// This is the core analysis engine of the upgrade helper. Unlike regex-based
/// search, it uses `package:analyzer` to parse Dart files into ASTs and then
/// visits nodes to find exact API usages with full type resolution, enclosing
/// scope information, and import source tracking.
///
/// Two analysis modes are supported:
/// - **Resolved** (default): Full type resolution via [getResolvedUnit]. Slower
///   but produces accurate [ApiMatch.resolvedType] and [ApiMatch.importSource].
/// - **Unresolved**: Fast parse via [getParsedUnit]. Only matches by name
///   without type info. Useful for quick scans.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;

import '../models/api_usage.dart';
import '../utils/logger.dart';

/// Default upper bound on files to analyze in a single run.
const int _kDefaultMaxFiles = 5000;

/// File suffixes that indicate generated code.
const List<String> _kGeneratedSuffixes = [
  '.g.dart',
  '.freezed.dart',
  '.mocks.dart',
  '.gr.dart',
  '.config.dart',
  '.chopper.dart',
  '.reflectable.dart',
];

/// Directory segments to skip during file discovery.
const List<String> _kExcludedDirSegments = [
  'build',
  '.dart_tool',
  '.build',
  '.fvm',
  '.symlinks',
  'ephemeral',
];

class CodebaseAnalyzer {

  /// Creates a [CodebaseAnalyzer].
  ///
  /// [maxFiles] caps the number of files analyzed. If omitted, the value is
  /// read from the `MAX_FILES_TO_ANALYZE` environment variable, falling back
  /// to [_kDefaultMaxFiles].
  CodebaseAnalyzer({int? maxFiles})
      : _maxFiles = maxFiles ??
            int.tryParse(
                Platform.environment['MAX_FILES_TO_ANALYZE'] ?? '') ??
            _kDefaultMaxFiles;
  /// Maximum number of Dart files to consider per scan.
  final int _maxFiles;

  // ---------------------------------------------------------------------------
  // File discovery
  // ---------------------------------------------------------------------------

  /// Find all Dart files under [projectPath], excluding generated files and
  /// build directories.
  ///
  /// Results are returned as absolute, normalized paths. The scan stops after
  /// [_maxFiles] files to avoid blowing up memory on monorepos.
  Future<List<String>> findDartFiles(String projectPath) async {
    final normalizedRoot = p.normalize(p.absolute(projectPath));
    final dir = Directory(normalizedRoot);

    if (!dir.existsSync()) {
      Logger.warn('Project path does not exist: $normalizedRoot');
      return const [];
    }

    final files = <String>[];

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;

      final relative = p.relative(entity.path, from: normalizedRoot);

      // Skip generated files.
      if (_isGenerated(relative)) continue;

      // Skip excluded directories.
      if (_isInExcludedDir(relative)) continue;

      files.add(p.normalize(entity.path));

      if (files.length >= _maxFiles) {
        Logger.warn(
          'Reached max files limit ($_maxFiles). '
          'Set MAX_FILES_TO_ANALYZE to increase.',
        );
        break;
      }
    }

    Logger.debug('Found ${files.length} Dart files in $normalizedRoot');
    return files;
  }

  /// Fast import scan: returns files under [projectPath] that contain an
  /// import of [packageName].
  ///
  /// This reads raw file text and matches import directives via regex.
  /// No AST parsing is performed, so it is much faster than
  /// [searchApiUsages].
  Future<List<String>> findFilesImporting(
    String projectPath,
    String packageName,
  ) async {
    final allFiles = await findDartFiles(projectPath);
    final importPattern = RegExp(
      r'''import\s+['"]package:''' +
          RegExp.escape(packageName) +
          r'''[/'"]''',
    );

    final matching = <String>[];
    for (final filePath in allFiles) {
      try {
        final content = await File(filePath).readAsString();
        if (importPattern.hasMatch(content)) {
          matching.add(filePath);
        }
      } catch (e) {
        Logger.debug('Could not read $filePath: $e');
      }
    }

    Logger.debug(
      'Found ${matching.length} files importing package:$packageName',
    );
    return matching;
  }

  // ---------------------------------------------------------------------------
  // API usage search (AST)
  // ---------------------------------------------------------------------------

  /// Search for usages of specific [apis] within [projectPath].
  ///
  /// When [packageFilter] is supplied the scan is restricted to files that
  /// import that package, and matches are validated against the resolved
  /// element's library URI. This dramatically reduces both I/O and analysis
  /// time.
  ///
  /// Set [resolveTypes] to `false` for a faster name-only scan that skips
  /// type resolution (useful for an initial broad pass).
  ///
  /// Returns one [ApiUsageResult] per entry in [apis], in the same order.
  Future<List<ApiUsageResult>> searchApiUsages({
    required String projectPath,
    required List<String> apis,
    String? packageFilter,
    bool resolveTypes = true,
  }) async {
    if (apis.isEmpty) return const [];

    // 1. Determine which files to analyze.
    List<String> filesToAnalyze;
    if (packageFilter != null) {
      filesToAnalyze = await findFilesImporting(projectPath, packageFilter);
    } else {
      filesToAnalyze = await findDartFiles(projectPath);
    }

    if (filesToAnalyze.isEmpty) {
      Logger.info('No files to analyze — returning empty results.');
      return apis
          .map((api) => ApiUsageResult(
                api: api,
                packageFilter: packageFilter,
                totalMatches: 0,
                matches: const [],
              ))
          .toList();
    }

    Logger.info(
      'Analyzing ${filesToAnalyze.length} file(s) for '
      '${apis.length} API(s)${resolveTypes ? ' (resolved)' : ' (unresolved)'}…',
    );

    // 2. Build the AnalysisContextCollection.
    //    Normalize every path to absolute form — the analyzer requires it.
    final normalizedPaths =
        filesToAnalyze.map((f) => p.normalize(p.absolute(f))).toList();

    final AnalysisContextCollection collection;
    try {
      collection = AnalysisContextCollection(
        includedPaths: normalizedPaths,
        resourceProvider: PhysicalResourceProvider.INSTANCE,
      );
    } catch (e, st) {
      Logger.error('Failed to create AnalysisContextCollection', e, st);
      return apis
          .map((api) => ApiUsageResult(
                api: api,
                packageFilter: packageFilter,
                totalMatches: 0,
                matches: const [],
              ))
          .toList();
    }

    // 3. Visit each file.
    final resultsMap = <String, List<ApiMatch>>{
      for (final api in apis) api: [],
    };

    var filesAnalyzed = 0;
    var filesErrored = 0;

    for (final context in collection.contexts) {
      for (final filePath in context.contextRoot.analyzedFiles()) {
        if (!filePath.endsWith('.dart')) continue;

        // Only analyze files the caller asked for. The context root may
        // include transitive dependencies — skip those.
        if (!normalizedPaths.contains(p.normalize(filePath))) continue;

        try {
          if (resolveTypes) {
            await _analyzeResolved(
              context: context,
              filePath: filePath,
              apis: apis,
              packageFilter: packageFilter,
              resultsMap: resultsMap,
            );
          } else {
            _analyzeUnresolved(
              context: context,
              filePath: filePath,
              apis: apis,
              resultsMap: resultsMap,
            );
          }
          filesAnalyzed++;
        } catch (e) {
          filesErrored++;
          Logger.debug('Error analyzing $filePath: $e');
        }
      }
    }

    Logger.info(
      'Analysis complete: $filesAnalyzed files analyzed, '
      '$filesErrored errors, '
      '${resultsMap.values.fold<int>(0, (sum, l) => sum + l.length)} total matches.',
    );

    return apis
        .map((api) => ApiUsageResult(
              api: api,
              packageFilter: packageFilter,
              totalMatches: resultsMap[api]!.length,
              matches: resultsMap[api]!,
            ))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Import summary / counting helpers
  // ---------------------------------------------------------------------------

  /// Count how many project files import [packageName]. Fast, no AST.
  Future<int> countImportingFiles(
      String projectPath, String packageName) async {
    final files = await findFilesImporting(projectPath, packageName);
    return files.length;
  }

  /// Build a map of `import URI -> [file paths]` for a given [packageName].
  ///
  /// This lets callers see which specific sub-libraries are imported and from
  /// where.
  Future<Map<String, List<String>>> getImportSummary(
    String projectPath,
    String packageName,
  ) async {
    final files = await findFilesImporting(projectPath, packageName);
    final summary = <String, List<String>>{};

    final importPattern = RegExp(
      r'''import\s+['"](package:''' +
          RegExp.escape(packageName) +
          r'''[^'"]*)['"]\s*;''',
    );

    for (final filePath in files) {
      try {
        final content = await File(filePath).readAsString();
        final matches = importPattern.allMatches(content);
        for (final match in matches) {
          final importUri = match.group(1)!;
          summary.putIfAbsent(importUri, () => []).add(filePath);
        }
      } catch (e) {
        Logger.debug('Could not read $filePath for import summary: $e');
      }
    }

    return summary;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Perform resolved analysis on a single file and collect matches.
  Future<void> _analyzeResolved({
    required dynamic context,
    required String filePath,
    required List<String> apis,
    required String? packageFilter,
    required Map<String, List<ApiMatch>> resultsMap,
  }) async {
    final result = await context.currentSession.getResolvedUnit(filePath);
    if (result is! ResolvedUnitResult) return;

    final visitor = _ApiUsageVisitor(
      apis: apis,
      packageFilter: packageFilter,
      filePath: filePath,
    );
    result.unit.visitChildren(visitor);

    for (final api in apis) {
      resultsMap[api]!.addAll(visitor.matchesFor(api));
    }
  }

  /// Perform unresolved (parse-only) analysis on a single file.
  void _analyzeUnresolved({
    required dynamic context,
    required String filePath,
    required List<String> apis,
    required Map<String, List<ApiMatch>> resultsMap,
  }) {
    final result = context.currentSession.getParsedUnit(filePath);
    if (result is! ParsedUnitResult) return;

    final visitor = _UnresolvedApiVisitor(
      apis: apis,
      filePath: filePath,
    );
    result.unit.visitChildren(visitor);

    for (final api in apis) {
      resultsMap[api]!.addAll(visitor.matchesFor(api));
    }
  }

  /// Whether [relativePath] has a suffix indicating it is generated code.
  static bool _isGenerated(String relativePath) {
    for (final suffix in _kGeneratedSuffixes) {
      if (relativePath.endsWith(suffix)) return true;
    }
    return false;
  }

  /// Whether [relativePath] passes through a directory we should skip.
  static bool _isInExcludedDir(String relativePath) {
    final segments = p.split(relativePath);
    for (final segment in segments) {
      for (final excluded in _kExcludedDirSegments) {
        if (segment == excluded) return true;
      }
    }
    return false;
  }
}

// =============================================================================
// AST visitors
// =============================================================================

/// Extracts the simple name portion from an API specifier.
///
/// Supports forms like `ClassName`, `methodName`, `ClassName.methodName`,
/// `ClassName.methodName()`. Always returns the last dot-separated segment
/// with trailing parentheses stripped.
String _simpleNameOf(String api) {
  return api.split('.').last.replaceAll('()', '');
}

/// Reads a single line from [filePath] at 1-based [lineNumber].
///
/// Returns the trimmed content, or an empty string on any failure.
String _readLineContent(String filePath, int lineNumber) {
  if (lineNumber <= 0) return '';
  try {
    final lines = File(filePath).readAsLinesSync();
    if (lineNumber <= lines.length) {
      return lines[lineNumber - 1].trim();
    }
  } catch (_) {
    // Intentionally swallowed — line content is best-effort.
  }
  return '';
}

// -----------------------------------------------------------------------------
// Resolved visitor
// -----------------------------------------------------------------------------

/// AST visitor that finds usages of specific APIs with full type resolution.
///
/// It checks:
/// - Method invocations (e.g. `widget.build()`)
/// - Constructor calls (e.g. `Provider()`, `Provider.value()`)
/// - Type references in annotations, generics, and declarations
/// - Simple and prefixed identifiers (e.g. `kDefaultTimeout`, `math.pi`)
///
/// When [packageFilter] is set, a match is only emitted if the resolved
/// element's library URI contains `package:<packageFilter>`.
class _ApiUsageVisitor extends RecursiveAstVisitor<void> {

  _ApiUsageVisitor({
    required this.apis,
    this.packageFilter,
    required this.filePath,
  }) : _matches = {for (final api in apis) api: []};
  final List<String> apis;
  final String? packageFilter;
  final String filePath;
  final Map<String, List<ApiMatch>> _matches;

  /// Cache of file lines so we do not re-read for every match in the same file.
  List<String>? _linesCache;

  /// Return the matches collected for [api].
  List<ApiMatch> matchesFor(String api) => _matches[api] ?? const [];

  // ---- Visitor overrides ----------------------------------------------------

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkIdentifier(node.methodName, node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final constructorName = node.constructorName;
    final typeName = constructorName.type.name2.lexeme;
    final element = constructorName.element;
    _checkElementMatch(typeName, element, node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _checkIdentifier(node.identifier, node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _checkIdentifier(node, node);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final name = node.name2.lexeme;
    final element = node.element2;
    _checkElementMatch(name, element, node);
    super.visitNamedType(node);
  }

  // ---- Matching logic -------------------------------------------------------

  void _checkIdentifier(SimpleIdentifier identifier, AstNode contextNode) {
    _checkElementMatch(identifier.name, identifier.element, contextNode);
  }

  void _checkElementMatch(String name, Element2? element, AstNode node) {
    for (final api in apis) {
      final simpleName = _simpleNameOf(api);
      if (name != simpleName) continue;

      // Validate against package filter when we have resolved element info.
      if (element != null && packageFilter != null) {
        final library = element.library2;
        if (library != null) {
          final libraryUri = library.uri.toString();
          if (!libraryUri.contains('package:$packageFilter')) continue;
        }
      }

      // For multi-part API names (e.g. "ClassName.methodName"), verify the
      // qualifier matches the enclosing type or the target's declaring class.
      if (api.contains('.')) {
        final qualifier = api.split('.').first;
        if (!_qualifierMatches(qualifier, element, node)) continue;
      }

      _recordMatch(api, element, node);
    }
  }

  /// Heuristic check that [qualifier] (the part before the dot in
  /// "ClassName.method") matches either the element's enclosing class or the
  /// AST target prefix.
  bool _qualifierMatches(String qualifier, Element2? element, AstNode node) {
    // Try resolved element first.
    if (element != null) {
      final enclosing = element.enclosingElement2;
      if (enclosing is InterfaceElement2 && enclosing.name3 == qualifier) {
        return true;
      }
      // Static accessors / top-level: the library's defining unit may house
      // a class with the right name. Fall through to AST check below.
    }

    // AST: if the node is the identifier of a PrefixedIdentifier, check the
    // prefix.
    final parent = node.parent;
    if (parent is PrefixedIdentifier && parent.identifier == node) {
      if (parent.prefix.name == qualifier) return true;
    }
    if (parent is MethodInvocation && parent.methodName == node) {
      final target = parent.target;
      if (target is SimpleIdentifier && target.name == qualifier) return true;
      if (target is PrefixedIdentifier &&
          target.identifier.name == qualifier) {
        return true;
      }
    }

    // Constructor: ClassName()
    if (node is InstanceCreationExpression) {
      final typeName = node.constructorName.type.name2.lexeme;
      if (typeName == qualifier) return true;
    }

    return false;
  }

  void _recordMatch(String api, Element2? element, AstNode node) {
    final unit = node.thisOrAncestorOfType<CompilationUnit>();
    final lineInfo = unit?.lineInfo;

    final offset = node.offset;
    final line = lineInfo?.getLocation(offset).lineNumber ?? 0;
    final column = lineInfo?.getLocation(offset).columnNumber ?? 0;

    // Enclosing class / mixin / extension.
    String? enclosingClass;
    final classDecl = node.thisOrAncestorOfType<ClassDeclaration>();
    if (classDecl != null) {
      enclosingClass = classDecl.name.lexeme;
    } else {
      final mixinDecl = node.thisOrAncestorOfType<MixinDeclaration>();
      if (mixinDecl != null) {
        enclosingClass = mixinDecl.name.lexeme;
      } else {
        final extDecl = node.thisOrAncestorOfType<ExtensionDeclaration>();
        if (extDecl != null) {
          enclosingClass = extDecl.name?.lexeme;
        }
      }
    }

    // Enclosing method or top-level function.
    String? enclosingMethod;
    final methodDecl = node.thisOrAncestorOfType<MethodDeclaration>();
    if (methodDecl != null) {
      enclosingMethod = methodDecl.name.lexeme;
    } else {
      final funcDecl = node.thisOrAncestorOfType<FunctionDeclaration>();
      if (funcDecl != null) {
        enclosingMethod = funcDecl.name.lexeme;
      }
    }

    // Resolved type information.
    String? resolvedType;
    if (element != null) {
      resolvedType = element.toString();
    }

    // Import source (library URI).
    String? importSource;
    if (element?.library2 != null) {
      importSource = element!.library2!.uri.toString();
    }

    // Line content (lazy-load and cache).
    final lineContent = _readLineFromCache(line);

    _matches[api]!.add(ApiMatch(
      filePath: filePath,
      line: line,
      column: column,
      lineContent: lineContent,
      resolvedType: resolvedType,
      enclosingClass: enclosingClass,
      enclosingMethod: enclosingMethod,
      importSource: importSource,
    ));
  }

  /// Read a line from the file, caching the entire file on first access so
  /// multiple matches in the same file don't trigger redundant I/O.
  String _readLineFromCache(int lineNumber) {
    if (lineNumber <= 0) return '';
    _linesCache ??= _safeReadLines(filePath);
    if (_linesCache == null || lineNumber > _linesCache!.length) return '';
    return _linesCache![lineNumber - 1].trim();
  }

  static List<String>? _safeReadLines(String path) {
    try {
      return File(path).readAsLinesSync();
    } catch (_) {
      return null;
    }
  }
}

// -----------------------------------------------------------------------------
// Unresolved visitor (fast, name-only)
// -----------------------------------------------------------------------------

/// A lighter-weight visitor that works on an unresolved parse tree.
///
/// It matches identifiers purely by name — no type checking, no library
/// filtering. Use this when speed matters more than precision (e.g., an
/// initial triage pass to see if any matches exist at all).
class _UnresolvedApiVisitor extends RecursiveAstVisitor<void> {

  _UnresolvedApiVisitor({
    required this.apis,
    required this.filePath,
  }) : _matches = {for (final api in apis) api: []};
  final List<String> apis;
  final String filePath;
  final Map<String, List<ApiMatch>> _matches;

  List<ApiMatch> matchesFor(String api) => _matches[api] ?? const [];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final name = node.name;
    for (final api in apis) {
      final simpleName = _simpleNameOf(api);
      if (name != simpleName) continue;

      final unit = node.thisOrAncestorOfType<CompilationUnit>();
      final lineInfo = unit?.lineInfo;
      final line = lineInfo?.getLocation(node.offset).lineNumber ?? 0;
      final column = lineInfo?.getLocation(node.offset).columnNumber ?? 0;

      // Best-effort line content even in unresolved mode.
      final lineContent = _readLineContent(filePath, line);

      // Best-effort enclosing scope from the unresolved AST.
      String? enclosingClass;
      final classDecl = node.thisOrAncestorOfType<ClassDeclaration>();
      if (classDecl != null) {
        enclosingClass = classDecl.name.lexeme;
      }

      String? enclosingMethod;
      final methodDecl = node.thisOrAncestorOfType<MethodDeclaration>();
      if (methodDecl != null) {
        enclosingMethod = methodDecl.name.lexeme;
      } else {
        final funcDecl = node.thisOrAncestorOfType<FunctionDeclaration>();
        if (funcDecl != null) {
          enclosingMethod = funcDecl.name.lexeme;
        }
      }

      _matches[api]!.add(ApiMatch(
        filePath: filePath,
        line: line,
        column: column,
        lineContent: lineContent,
        resolvedType: null,
        enclosingClass: enclosingClass,
        enclosingMethod: enclosingMethod,
        importSource: null,
      ));
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final name = node.name2.lexeme;
    for (final api in apis) {
      final simpleName = _simpleNameOf(api);
      if (name != simpleName) continue;

      final unit = node.thisOrAncestorOfType<CompilationUnit>();
      final lineInfo = unit?.lineInfo;
      final line = lineInfo?.getLocation(node.offset).lineNumber ?? 0;
      final column = lineInfo?.getLocation(node.offset).columnNumber ?? 0;

      _matches[api]!.add(ApiMatch(
        filePath: filePath,
        line: line,
        column: column,
        lineContent: _readLineContent(filePath, line),
        resolvedType: null,
        enclosingClass: null,
        enclosingMethod: null,
        importSource: null,
      ));
    }
    super.visitNamedType(node);
  }
}
