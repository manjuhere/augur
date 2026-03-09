import '../models/migration_plan.dart';
import '../services/pubspec_parser.dart';
import '../services/version_resolver.dart';
import '../tools/analyze_impact.dart';
import '../utils/logger.dart';

/// Tool that generates an ordered, actionable migration plan for one or more
/// package upgrades in a Flutter/Dart project.
///
/// The plan includes:
/// - Ordered migration steps (pubspec changes, code changes, commands)
/// - Effort estimation based on impact analysis
/// - Prerequisites and warnings
///
/// This tool orchestrates [PubspecParser], [AnalyzeImpactTool], and
/// [VersionResolver] to produce a comprehensive migration strategy.
class GenerateMigrationPlanTool {
  final PubspecParser _pubspecParser;
  final VersionResolver _versionResolver;
  final AnalyzeImpactTool _analyzeImpact;

  GenerateMigrationPlanTool(
    this._pubspecParser,
    this._versionResolver,
    this._analyzeImpact,
  );

  /// Execute the generate_migration_plan tool.
  ///
  /// Input arguments:
  /// - `projectPath` (String, required): Path to the Flutter/Dart project root.
  /// - `upgrades` (List<Map>, required): List of upgrades, each containing
  ///   `packageName` (String) and `targetVersion` (String).
  /// - `analysisDepth` (String, optional): Depth of impact analysis. One of
  ///   `file_level`, `line_level`, or `symbol_level`. Defaults to `file_level`.
  ///
  /// Returns a JSON-serialisable map representing the [MigrationPlan].
  Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final projectPath = args['projectPath'] as String;
    final upgrades = (args['upgrades'] as List).cast<Map<String, dynamic>>();
    final analysisDepth = args['analysisDepth'] as String? ?? 'file_level';

    Logger.info('Generating migration plan for ${upgrades.length} upgrade(s)');

    if (upgrades.isEmpty) {
      return MigrationPlan(
        steps: const [],
        estimatedEffort: EffortLevel.trivial,
        effortDescription: 'No upgrades requested.',
        prerequisites: const [],
        warnings: const ['No upgrades were provided.'],
      ).toJson();
    }

    // Parse the project's pubspec to understand current dependency state.
    final pubspec = await _pubspecParser.parse(projectPath);

    // -----------------------------------------------------------------------
    // Step 1: Run impact analysis for each requested upgrade.
    // -----------------------------------------------------------------------
    final analysisByPackage = <String, Map<String, dynamic>>{};
    for (final upgrade in upgrades) {
      final packageName = upgrade['packageName'] as String;
      final targetVersion = upgrade['targetVersion'] as String;

      try {
        final result = await _analyzeImpact.execute(
          projectPath: projectPath,
          packageName: packageName,
          targetVersion: targetVersion,
          analysisDepth: analysisDepth,
          includeCascading: true,
        );
        analysisByPackage[packageName] = result;
      } catch (e) {
        Logger.warn('Failed to analyze impact for $packageName: $e');
        analysisByPackage[packageName] = {'error': e.toString()};
      }
    }

    // -----------------------------------------------------------------------
    // Step 2: Determine upgrade order (dependencies-first topological sort).
    // -----------------------------------------------------------------------
    final orderedUpgrades = _orderUpgrades(upgrades, analysisByPackage);

    // -----------------------------------------------------------------------
    // Step 3: Build the list of migration steps.
    // -----------------------------------------------------------------------
    final steps = <MigrationStep>[];
    var stepOrder = 1;
    final allWarnings = <String>[];
    final prerequisites = <String>[
      'Ensure all tests pass before starting migration',
      'Create a backup branch: git checkout -b pre-migration-backup',
      'Ensure you have a clean working tree (no uncommitted changes)',
    ];

    for (final upgrade in orderedUpgrades) {
      final packageName = upgrade['packageName'] as String;
      final targetVersion = upgrade['targetVersion'] as String;
      final analysis = analysisByPackage[packageName];

      // Look up the current dependency entry.
      final currentDep = pubspec.dependencies[packageName] ??
          pubspec.devDependencies[packageName];

      final currentVersion = currentDep?.resolvedVersion;
      final currentConstraint = currentDep?.versionConstraint;

      // -- Warn if the package is not found in pubspec --
      if (currentDep == null) {
        allWarnings.add(
          '$packageName is not listed in pubspec.yaml; '
          'it will be added as a new dependency.',
        );
      }

      // -- Warn if analysis produced an error --
      if (analysis != null && analysis.containsKey('error')) {
        allWarnings.add(
          'Impact analysis for $packageName failed: ${analysis['error']}. '
          'Manual review is recommended.',
        );
      }

      // -- Warn about non-hosted sources --
      if (currentDep != null && currentDep.source != 'hosted') {
        allWarnings.add(
          '$packageName uses source "${currentDep.source}"; '
          'automatic version constraint update may not apply.',
        );
      }

      // -----------------------------------------------------------------
      // Sub-step A: Update pubspec.yaml
      // -----------------------------------------------------------------
      final suggestedConstraint =
          _versionResolver.suggestConstraint(targetVersion);

      steps.add(MigrationStep(
        order: stepOrder++,
        type: StepType.pubspecChange,
        description: 'Update $packageName to $targetVersion in pubspec.yaml',
        packageName: packageName,
        targetVersion: targetVersion,
        codeChanges: [
          CodeChange(
            filePath: 'pubspec.yaml',
            line: 0,
            before: '$packageName: ${currentConstraint ?? "any"}',
            after: '$packageName: $suggestedConstraint',
            explanation:
                'Update version constraint for $packageName to allow $targetVersion',
          ),
        ],
      ));

      // -----------------------------------------------------------------
      // Sub-step B: Run dependency resolution
      // -----------------------------------------------------------------
      steps.add(MigrationStep(
        order: stepOrder++,
        type: StepType.runCommand,
        description: 'Resolve updated dependencies for $packageName',
        packageName: packageName,
        command: 'dart pub get',
      ));

      // -----------------------------------------------------------------
      // Sub-step C: Handle cascading dependency conflicts
      // -----------------------------------------------------------------
      if (analysis != null && analysis['cascadingImpacts'] is List) {
        final cascading = analysis['cascadingImpacts'] as List;
        for (final impact in cascading) {
          if (impact is Map<String, dynamic>) {
            final depName = impact['dependencyName'] as String? ?? 'unknown';
            final requiredBy = impact['requiredBy'] as String? ?? packageName;
            final currentConstraintStr =
                impact['currentConstraint'] as String? ?? 'any';
            final conflictReason = impact['conflictReason'] as String?;

            steps.add(MigrationStep(
              order: stepOrder++,
              type: StepType.manual,
              description:
                  'Resolve cascading dependency conflict: $depName '
                  '(required by $requiredBy, current constraint: '
                  '$currentConstraintStr)',
              packageName: depName,
              codeChanges: [
                CodeChange(
                  filePath: 'pubspec.yaml',
                  line: 0,
                  before: '$depName: $currentConstraintStr',
                  after: '$depName: // Update to a compatible version',
                  explanation: conflictReason ??
                      'This dependency may need a version bump to be '
                          'compatible with $packageName $targetVersion',
                ),
              ],
            ));

            allWarnings.add(
              'Cascading impact: $depName may need updating due to '
              '$packageName upgrade (required by $requiredBy).',
            );
          }
        }
      }

      // -----------------------------------------------------------------
      // Sub-step D: Apply code changes based on breaking change impacts
      // -----------------------------------------------------------------
      if (analysis != null && analysis['impacts'] is List) {
        final impacts = analysis['impacts'] as List;
        for (final impact in impacts) {
          if (impact is Map<String, dynamic>) {
            final breakingChange =
                impact['breakingChange'] as Map<String, dynamic>?;
            final locations = impact['affectedLocations'] as List?;
            final suggestedFix = impact['suggestedFix'] as String?;

            if (locations != null && locations.isNotEmpty) {
              final codeChanges = <CodeChange>[];
              for (final loc in locations) {
                if (loc is Map<String, dynamic>) {
                  codeChanges.add(CodeChange(
                    filePath: loc['filePath'] as String? ?? '',
                    line: loc['line'] as int? ?? 0,
                    before: loc['lineContent'] as String? ?? '',
                    after: suggestedFix ?? '// TODO: Update this usage',
                    explanation: breakingChange?['description'] as String?,
                  ));
                }
              }

              if (codeChanges.isNotEmpty) {
                final changeDescription =
                    breakingChange?['description'] as String? ??
                        'Update code for $packageName breaking change';
                final changeSeverity =
                    breakingChange?['severity'] as String? ?? 'major';
                final changeCategory =
                    breakingChange?['category'] as String? ?? 'unknown';
                final affectedApi =
                    breakingChange?['affectedApi'] as String?;

                final descParts = <String>[changeDescription];
                if (affectedApi != null) {
                  descParts.add('(API: $affectedApi)');
                }

                steps.add(MigrationStep(
                  order: stepOrder++,
                  type: StepType.codeChange,
                  description: descParts.join(' '),
                  packageName: packageName,
                  targetVersion: targetVersion,
                  codeChanges: codeChanges,
                ));

                // Add warnings for critical breaking changes.
                if (changeSeverity == 'critical') {
                  allWarnings.add(
                    'Critical breaking change in $packageName: '
                    '$changeDescription '
                    '(affects ${codeChanges.length} location(s))',
                  );
                }
              }
            } else if (breakingChange != null) {
              // Breaking change with no detected locations — add as manual step
              // so it is not silently ignored.
              final description =
                  breakingChange['description'] as String? ??
                      'Undetected breaking change in $packageName';
              final migrationGuide =
                  breakingChange['migrationGuide'] as String?;

              steps.add(MigrationStep(
                order: stepOrder++,
                type: StepType.manual,
                description:
                    'Review breaking change: $description'
                    '${migrationGuide != null ? " (see: $migrationGuide)" : ""}',
                packageName: packageName,
                targetVersion: targetVersion,
              ));
            }
          }
        }
      }

      // -----------------------------------------------------------------
      // Sub-step E: Run dart fix for major version bumps
      // -----------------------------------------------------------------
      final resolvedCurrentVersion = currentVersion ?? '0.0.0';
      if (_isMajorBumpSafe(resolvedCurrentVersion, targetVersion)) {
        steps.add(MigrationStep(
          order: stepOrder++,
          type: StepType.runCommand,
          description:
              'Apply automated dart fix suggestions for $packageName',
          packageName: packageName,
          command: 'dart fix --apply',
        ));
      }

      // -----------------------------------------------------------------
      // Sub-step F: Run static analysis
      // -----------------------------------------------------------------
      steps.add(MigrationStep(
        order: stepOrder++,
        type: StepType.runCommand,
        description: 'Run static analysis after $packageName migration',
        packageName: packageName,
        command: 'dart analyze',
      ));

      // -- Collect warnings from analysis result --
      if (analysis != null && analysis['warnings'] is List) {
        final analysisWarnings = analysis['warnings'] as List;
        for (final w in analysisWarnings) {
          if (w is String && !allWarnings.contains(w)) {
            allWarnings.add(w);
          }
        }
      }
    }

    // -----------------------------------------------------------------------
    // Step 4: Final verification steps
    // -----------------------------------------------------------------------
    steps.add(MigrationStep(
      order: stepOrder++,
      type: StepType.runCommand,
      description: 'Run full static analysis to verify migration',
      command: 'dart analyze',
    ));

    steps.add(MigrationStep(
      order: stepOrder++,
      type: StepType.runCommand,
      description: 'Run all tests to verify migration',
      command: 'dart test',
    ));

    steps.add(MigrationStep(
      order: stepOrder++,
      type: StepType.manual,
      description: 'Review all changes and run integration/manual tests',
    ));

    // -----------------------------------------------------------------------
    // Step 5: Estimate overall effort
    // -----------------------------------------------------------------------
    final effort = _estimateEffort(analysisByPackage);

    final plan = MigrationPlan(
      steps: steps,
      estimatedEffort: effort,
      effortDescription: _effortDescription(effort, upgrades.length),
      prerequisites: prerequisites,
      warnings: allWarnings,
    );

    Logger.info(
      'Migration plan generated: ${steps.length} step(s), '
      'effort: ${effort.name}',
    );

    return plan.toJson();
  }

  // =========================================================================
  // Upgrade ordering
  // =========================================================================

  /// Order upgrades so that packages with fewer cascading impacts are upgraded
  /// first (i.e. foundational dependencies come before dependents).
  ///
  /// This uses a heuristic based on cascading impact count: packages that
  /// cause cascading impacts on other packages should be upgraded first so
  /// their consumers can resolve against the new version.
  ///
  /// For a fully correct topological sort we would need a dependency graph, but
  /// the cascading-impact heuristic gives a reasonable approximation.
  List<Map<String, dynamic>> _orderUpgrades(
    List<Map<String, dynamic>> upgrades,
    Map<String, Map<String, dynamic>> analyses,
  ) {
    // Build a set of package names in the upgrade list for cross-referencing.
    final upgradePackageNames =
        upgrades.map((u) => u['packageName'] as String).toSet();

    // Build a simple dependency graph: if upgrading A has a cascading impact
    // on B (and B is also being upgraded), then A should come before B.
    final dependsOn = <String, Set<String>>{};
    for (final packageName in upgradePackageNames) {
      dependsOn[packageName] = {};
    }

    for (final entry in analyses.entries) {
      final packageName = entry.key;
      final analysis = entry.value;
      final cascading = analysis['cascadingImpacts'] as List?;
      if (cascading == null) continue;

      for (final impact in cascading) {
        if (impact is Map<String, dynamic>) {
          final dependencyName = impact['dependencyName'] as String?;
          // If a cascading impact's dependency is also in our upgrade list,
          // that dependency should be upgraded first.
          if (dependencyName != null &&
              upgradePackageNames.contains(dependencyName)) {
            dependsOn[packageName]?.add(dependencyName);
          }
        }
      }
    }

    // Topological sort via Kahn's algorithm.
    final sorted = <String>[];
    final inDegree = <String, int>{};
    for (final pkg in upgradePackageNames) {
      inDegree[pkg] = 0;
    }
    for (final entry in dependsOn.entries) {
      for (final dep in entry.value) {
        inDegree[entry.key] = (inDegree[entry.key] ?? 0) + 1;
      }
    }

    final queue = <String>[
      ...upgradePackageNames.where((pkg) => (inDegree[pkg] ?? 0) == 0),
    ];
    // Sort the initial queue alphabetically for deterministic output.
    queue.sort();

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      sorted.add(current);

      for (final pkg in upgradePackageNames) {
        if (dependsOn[pkg]?.contains(current) ?? false) {
          dependsOn[pkg]!.remove(current);
          inDegree[pkg] = (inDegree[pkg] ?? 1) - 1;
          if (inDegree[pkg] == 0) {
            queue.add(pkg);
          }
        }
      }
    }

    // If there are cycles (packages not yet sorted), append them at the end
    // with a warning logged.
    final remaining =
        upgradePackageNames.where((p) => !sorted.contains(p)).toList()..sort();
    if (remaining.isNotEmpty) {
      Logger.warn(
        'Circular dependency detected among: ${remaining.join(", ")}. '
        'Appending in alphabetical order.',
      );
      sorted.addAll(remaining);
    }

    // Map sorted names back to the original upgrade maps.
    final upgradeByName = <String, Map<String, dynamic>>{};
    for (final upgrade in upgrades) {
      upgradeByName[upgrade['packageName'] as String] = upgrade;
    }

    return sorted
        .where((name) => upgradeByName.containsKey(name))
        .map((name) => upgradeByName[name]!)
        .toList();
  }

  // =========================================================================
  // Effort estimation
  // =========================================================================

  /// Estimate the overall effort level based on aggregate impact analysis.
  EffortLevel _estimateEffort(
    Map<String, Map<String, dynamic>> analyses,
  ) {
    var totalLocations = 0;
    var totalFiles = 0;
    var hasCritical = false;
    var hasHigh = false;
    var breakingChangeCount = 0;

    for (final analysis in analyses.values) {
      if (analysis.containsKey('error')) continue;

      totalLocations +=
          (analysis['totalLocationsAffected'] as int?) ?? 0;
      totalFiles += (analysis['totalFilesAffected'] as int?) ?? 0;

      final riskLevel = analysis['riskLevel'] as String?;
      if (riskLevel == 'critical') hasCritical = true;
      if (riskLevel == 'high') hasHigh = true;

      final impacts = analysis['impacts'] as List?;
      if (impacts != null) {
        breakingChangeCount += impacts.length;
      }
    }

    if (hasCritical || totalLocations > 100 || breakingChangeCount > 10) {
      return EffortLevel.high;
    }
    if (hasHigh || totalLocations > 30 || breakingChangeCount > 5) {
      return EffortLevel.medium;
    }
    if (totalLocations > 5 || breakingChangeCount > 1) {
      return EffortLevel.low;
    }
    return EffortLevel.trivial;
  }

  /// Produce a human-readable effort description.
  String _effortDescription(EffortLevel level, int upgradeCount) {
    final packageWord = upgradeCount == 1 ? 'package' : 'packages';
    switch (level) {
      case EffortLevel.trivial:
        return 'Minimal changes needed across $upgradeCount $packageWord. '
            'Mostly pubspec updates and dependency resolution.';
      case EffortLevel.low:
        return 'A few code changes required across $upgradeCount $packageWord. '
            'Estimated time: under 1 hour.';
      case EffortLevel.medium:
        return 'Moderate refactoring needed for $upgradeCount $packageWord. '
            'Plan for focused development time (1-4 hours).';
      case EffortLevel.high:
        return 'Significant migration effort for $upgradeCount $packageWord. '
            'Consider breaking into smaller PRs and allocating 4+ hours.';
    }
  }

  // =========================================================================
  // Utility helpers
  // =========================================================================

  /// Safely check for a major version bump, handling parse errors gracefully.
  bool _isMajorBumpSafe(String from, String to) {
    try {
      return _versionResolver.isMajorBump(from, to);
    } catch (e) {
      Logger.debug(
        'Could not determine major bump for $from -> $to: $e',
      );
      return false;
    }
  }
}
