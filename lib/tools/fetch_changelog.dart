import '../services/pub_api_client.dart';
import '../services/github_client.dart';
import '../services/changelog_parser.dart';
import '../utils/logger.dart';

class FetchChangelogTool {

  FetchChangelogTool(
      this._pubApi, this._github, this._changelogParser);
  final PubApiClient _pubApi;
  final GitHubClient _github;
  final ChangelogParser _changelogParser;

  /// Execute fetch_changelog
  /// Input: packageName, fromVersion?, toVersion?, maxEntries?
  /// Output: structured changelog entries
  Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final packageName = args['packageName'] as String;
    final fromVersion = args['fromVersion'] as String?;
    final toVersion = args['toVersion'] as String?;
    final maxEntries = args['maxEntries'] as int? ?? 50;

    Logger.info('Fetching changelog for $packageName');

    // Try to get changelog from GitHub first (better formatting)
    String? changelogContent;
    final repoUrl = await _pubApi.getRepositoryUrl(packageName);
    if (repoUrl != null) {
      final parsed = GitHubClient.parseGitHubUrl(repoUrl);
      if (parsed != null) {
        changelogContent = await _github.fetchChangelog(parsed.$1, parsed.$2);
      }
    }

    if (changelogContent == null || changelogContent.isEmpty) {
      return {
        'packageName': packageName,
        'error': 'Could not fetch changelog',
        'entries': [],
      };
    }

    var entries = _changelogParser.parse(changelogContent);

    // Filter by version range if specified
    if (fromVersion != null || toVersion != null) {
      entries = _changelogParser.getEntriesBetween(
        entries,
        fromVersion ?? '0.0.0',
        toVersion ?? '999.999.999',
      );
    }

    // Limit entries
    if (entries.length > maxEntries) {
      entries = entries.take(maxEntries).toList();
    }

    return {
      'packageName': packageName,
      'fromVersion': fromVersion,
      'toVersion': toVersion,
      'entryCount': entries.length,
      'hasBreakingChanges': entries.any((e) => e.hasBreakingChanges),
      'entries': entries.map((e) => e.toJson()).toList(),
    };
  }
}
