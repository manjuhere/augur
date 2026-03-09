import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart' hide Logger;

import 'package:augur/cache/cache_manager.dart';
import 'package:augur/services/pub_api_client.dart';
import 'package:augur/services/github_client.dart';
import 'package:augur/services/flutter_docs_client.dart';
import 'package:augur/services/changelog_parser.dart';
import 'package:augur/services/codebase_analyzer.dart';
import 'package:augur/services/pubspec_parser.dart';
import 'package:augur/services/version_resolver.dart';
import 'package:augur/services/cascade_resolver.dart';
import 'package:augur/tools/scan_project.dart';
import 'package:augur/tools/check_upgrades.dart';
import 'package:augur/tools/analyze_impact.dart';
import 'package:augur/tools/generate_migration_plan.dart';
import 'package:augur/tools/fetch_changelog.dart';
import 'package:augur/tools/search_api_usage.dart';
import 'package:augur/utils/http_client.dart';
import 'package:augur/utils/logger.dart';

/// The main MCP server for Augur.
///
/// Creates an [McpServer] instance, registers all six tools with their JSON
/// schemas, and exposes a [run] method that connects via stdio transport.
class AugurServer {

  AugurServer() {
    _initServices();
    _initServer();
    _registerTools();
  }
  late final McpServer _server;

  // Services
  late final CacheManager _cacheManager;
  late final HttpClientWrapper _httpClient;
  late final PubspecParser _pubspecParser;
  late final PubApiClient _pubApiClient;
  late final GitHubClient _githubClient;
  late final FlutterDocsClient _flutterDocsClient;
  late final ChangelogParser _changelogParser;
  late final CodebaseAnalyzer _codebaseAnalyzer;
  late final VersionResolver _versionResolver;
  late final CascadeResolver _cascadeResolver;

  /// Initialise all shared service instances.
  void _initServices() {
    _cacheManager = CacheManager();
    _httpClient = HttpClientWrapper();
    _pubspecParser = PubspecParser();
    _pubApiClient = PubApiClient(
      cacheManager: _cacheManager,
      httpClient: _httpClient,
    );
    _githubClient = GitHubClient(
      cacheManager: _cacheManager,
      httpClient: _httpClient,
    );
    _flutterDocsClient = FlutterDocsClient(
      cacheManager: _cacheManager,
      httpClient: _httpClient,
    );
    _changelogParser = ChangelogParser();
    _codebaseAnalyzer = CodebaseAnalyzer();
    _versionResolver = VersionResolver();
    _cascadeResolver = CascadeResolver(_pubApiClient, _versionResolver);
  }

  /// Create the MCP server with metadata and capabilities.
  void _initServer() {
    _server = McpServer(
      const Implementation(name: 'augur', version: '1.0.0'),
      options: const McpServerOptions(
        capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      ),
    );
  }

  /// Register all six tools with their input schemas and handlers.
  void _registerTools() {
    _registerScanProject();
    _registerCheckAvailableUpgrades();
    _registerAnalyzeUpgradeImpact();
    _registerGenerateMigrationPlan();
    _registerFetchChangelog();
    _registerSearchApiUsage();
    Logger.info('All tools registered successfully');
  }

  // ---------------------------------------------------------------------------
  // Tool registrations
  // ---------------------------------------------------------------------------

  void _registerScanProject() {
    _server.registerTool(
      'scan_project',
      description:
          'Scan a Flutter/Dart project to discover all dependencies, their '
          'current versions, version constraints, and SDK requirements. '
          'Parses pubspec.yaml and pubspec.lock.',
      inputSchema: _schema({
        'type': 'object',
        'properties': {
          'projectPath': {
            'type': 'string',
            'description':
                'Absolute path to the Flutter/Dart project root directory.',
          },
          'includeDevDependencies': {
            'type': 'boolean',
            'description':
                'Whether to include dev_dependencies in the scan results.',
            'default': true,
          },
          'includeTransitive': {
            'type': 'boolean',
            'description':
                'Whether to include transitive dependencies from pubspec.lock.',
            'default': false,
          },
        },
        'required': ['projectPath'],
      }),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) async {
        Logger.debug('scan_project called with: $args');
        try {
          final tool = ScanProjectTool(_pubspecParser);
          final result = await tool.execute(args);
          return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
          );
        } catch (e, stack) {
          Logger.error('scan_project failed', e, stack);
          return _errorResult('scan_project failed: $e');
        }
      },
    );
  }

  void _registerCheckAvailableUpgrades() {
    _server.registerTool(
      'check_available_upgrades',
      description:
          'Check available upgrades for project dependencies. Can target a '
          'specific package or all packages. Optionally filters by Flutter SDK '
          'compatibility.',
      inputSchema: _schema({
        'type': 'object',
        'properties': {
          'projectPath': {
            'type': 'string',
            'description':
                'Absolute path to the Flutter/Dart project root directory.',
          },
          'packageName': {
            'type': 'string',
            'description':
                'Specific package to check. If omitted, all dependencies are checked.',
          },
          'includePrerelease': {
            'type': 'boolean',
            'description': 'Whether to include pre-release versions.',
            'default': false,
          },
          'targetFlutterVersion': {
            'type': 'string',
            'description':
                'Filter upgrades compatible with this Flutter SDK version '
                '(e.g. "3.24.0").',
          },
        },
        'required': ['projectPath'],
      }),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) async {
        Logger.debug('check_available_upgrades called with: $args');
        try {
          final tool = CheckUpgradesTool(
            _pubspecParser,
            _pubApiClient,
            _versionResolver,
          );
          final result = await tool.execute(args);
          return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
          );
        } catch (e, stack) {
          Logger.error('check_available_upgrades failed', e, stack);
          return _errorResult('check_available_upgrades failed: $e');
        }
      },
    );
  }

  void _registerAnalyzeUpgradeImpact() {
    _server.registerTool(
      'analyze_upgrade_impact',
      description:
          'Analyze the impact of upgrading a specific package to a target version. '
          'Identifies breaking changes, affected code locations, and cascading '
          'dependency effects.',
      inputSchema: _schema({
        'type': 'object',
        'properties': {
          'projectPath': {
            'type': 'string',
            'description':
                'Absolute path to the Flutter/Dart project root directory.',
          },
          'packageName': {
            'type': 'string',
            'description': 'The package to analyze for upgrade impact.',
          },
          'targetVersion': {
            'type': 'string',
            'description':
                'The version to upgrade to (e.g. "2.0.0").',
          },
          'analysisDepth': {
            'type': 'string',
            'enum': ['summary', 'file_level', 'line_level'],
            'description':
                'How detailed the analysis should be. '
                '"summary" gives an overview, "file_level" lists affected files, '
                '"line_level" pinpoints exact code locations.',
            'default': 'file_level',
          },
          'includeCascading': {
            'type': 'boolean',
            'description':
                'Whether to analyze cascading impacts on other dependencies.',
            'default': true,
          },
        },
        'required': ['projectPath', 'packageName', 'targetVersion'],
      }),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) async {
        Logger.debug('analyze_upgrade_impact called with: $args');
        try {
          final tool = AnalyzeImpactTool(
            pubspecParser: _pubspecParser,
            pubApiClient: _pubApiClient,
            githubClient: _githubClient,
            flutterDocsClient: _flutterDocsClient,
            changelogParser: _changelogParser,
            codebaseAnalyzer: _codebaseAnalyzer,
            versionResolver: _versionResolver,
            cascadeResolver: _cascadeResolver,
          );
          final result = await tool.execute(
            projectPath: args['projectPath'] as String,
            packageName: args['packageName'] as String,
            targetVersion: args['targetVersion'] as String,
            analysisDepth: args['analysisDepth'] as String? ?? 'file_level',
            includeCascading: args['includeCascading'] as bool? ?? true,
          );
          return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
          );
        } catch (e, stack) {
          Logger.error('analyze_upgrade_impact failed', e, stack);
          return _errorResult('analyze_upgrade_impact failed: $e');
        }
      },
    );
  }

  void _registerGenerateMigrationPlan() {
    _server.registerTool(
      'generate_migration_plan',
      description:
          'Generate an ordered migration plan for upgrading one or more packages. '
          'Produces step-by-step instructions including pubspec changes, code '
          'modifications, and commands to run.',
      inputSchema: _schema({
        'type': 'object',
        'properties': {
          'projectPath': {
            'type': 'string',
            'description':
                'Absolute path to the Flutter/Dart project root directory.',
          },
          'upgrades': {
            'type': 'array',
            'description': 'List of packages and their target versions.',
            'items': {
              'type': 'object',
              'properties': {
                'packageName': {
                  'type': 'string',
                  'description': 'The package name to upgrade.',
                },
                'targetVersion': {
                  'type': 'string',
                  'description': 'The target version to upgrade to.',
                },
              },
              'required': ['packageName', 'targetVersion'],
            },
            'minItems': 1,
          },
          'analysisDepth': {
            'type': 'string',
            'enum': ['summary', 'file_level', 'line_level'],
            'description':
                'How detailed the migration plan should be.',
            'default': 'file_level',
          },
        },
        'required': ['projectPath', 'upgrades'],
      }),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) async {
        Logger.debug('generate_migration_plan called with: $args');
        try {
          final analyzeImpactTool = AnalyzeImpactTool(
            pubspecParser: _pubspecParser,
            pubApiClient: _pubApiClient,
            githubClient: _githubClient,
            flutterDocsClient: _flutterDocsClient,
            changelogParser: _changelogParser,
            codebaseAnalyzer: _codebaseAnalyzer,
            versionResolver: _versionResolver,
            cascadeResolver: _cascadeResolver,
          );
          final tool = GenerateMigrationPlanTool(
            _pubspecParser,
            _versionResolver,
            analyzeImpactTool,
          );
          final result = await tool.execute(args);
          return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
          );
        } catch (e, stack) {
          Logger.error('generate_migration_plan failed', e, stack);
          return _errorResult('generate_migration_plan failed: $e');
        }
      },
    );
  }

  void _registerFetchChangelog() {
    _server.registerTool(
      'fetch_changelog',
      description:
          'Fetch and parse the changelog for a package, optionally filtered to a '
          'version range. Returns structured entries with version, date, and '
          'categorised changes.',
      inputSchema: _schema({
        'type': 'object',
        'properties': {
          'packageName': {
            'type': 'string',
            'description': 'The pub.dev package name.',
          },
          'fromVersion': {
            'type': 'string',
            'description':
                'Start of the version range (exclusive). Only entries newer '
                'than this version are returned.',
          },
          'toVersion': {
            'type': 'string',
            'description':
                'End of the version range (inclusive). Only entries up to and '
                'including this version are returned.',
          },
          'maxEntries': {
            'type': 'integer',
            'description': 'Maximum number of changelog entries to return.',
            'default': 50,
          },
        },
        'required': ['packageName'],
      }),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) async {
        Logger.debug('fetch_changelog called with: $args');
        try {
          final tool = FetchChangelogTool(
            _pubApiClient,
            _githubClient,
            _changelogParser,
          );
          final result = await tool.execute(args);
          return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
          );
        } catch (e, stack) {
          Logger.error('fetch_changelog failed', e, stack);
          return _errorResult('fetch_changelog failed: $e');
        }
      },
    );
  }

  void _registerSearchApiUsage() {
    _server.registerTool(
      'search_api_usage',
      description:
          'Search for usages of specific APIs across the project codebase. '
          'Uses AST-based analysis for accurate results including resolved '
          'types, enclosing scopes, and import sources.',
      inputSchema: _schema({
        'type': 'object',
        'properties': {
          'projectPath': {
            'type': 'string',
            'description':
                'Absolute path to the Flutter/Dart project root directory.',
          },
          'apis': {
            'type': 'array',
            'description':
                'List of API identifiers to search for (e.g. class names, '
                'method names, function names).',
            'items': {
              'type': 'string',
            },
            'minItems': 1,
          },
          'packageFilter': {
            'type': 'string',
            'description':
                'Only match usages that originate from this package '
                '(filters by import source).',
          },
        },
        'required': ['projectPath', 'apis'],
      }),
      callback: (Map<String, dynamic> args, RequestHandlerExtra extra) async {
        Logger.debug('search_api_usage called with: $args');
        try {
          final tool = SearchApiUsageTool(_codebaseAnalyzer);
          final result = await tool.execute(args);
          return CallToolResult(
            content: [TextContent(text: jsonEncode(result))],
          );
        } catch (e, stack) {
          Logger.error('search_api_usage failed', e, stack);
          return _errorResult('search_api_usage failed: $e');
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Convert a raw schema map to [JsonObject] for tool registration.
  static JsonObject _schema(Map<String, dynamic> map) =>
      JsonObject.fromJson(map);

  /// Produce an error [CallToolResult] for tool failures.
  CallToolResult _errorResult(String message) {
    return CallToolResult(
      content: [TextContent(text: jsonEncode({'error': message}))],
      isError: true,
    );
  }

  /// Connect the server to stdio transport and begin processing requests.
  Future<void> run() async {
    Logger.info('Connecting via stdio transport...');
    final transport = StdioServerTransport();
    await _server.connect(transport);
    Logger.info('Augur MCP server is running');
  }
}
