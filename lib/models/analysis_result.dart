/// Models for impact analysis results.
library;

import 'breaking_change.dart';

enum RiskLevel { low, medium, high, critical }

class AnalysisResult {
  const AnalysisResult({
    required this.packageName,
    required this.currentVersion,
    required this.targetVersion,
    required this.riskLevel,
    required this.riskScore,
    required this.totalFilesAffected,
    required this.totalLocationsAffected,
    required this.impacts,
    required this.cascadingImpacts,
    this.warnings = const [],
    this.overallConfidence = 1.0,
  });

  final String packageName;
  final String currentVersion;
  final String targetVersion;
  final RiskLevel riskLevel;
  final double riskScore;
  final int totalFilesAffected;
  final int totalLocationsAffected;
  final List<BreakingChangeImpact> impacts;
  final List<CascadingImpact> cascadingImpacts;
  final List<String> warnings;
  final double overallConfidence;

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'currentVersion': currentVersion,
        'targetVersion': targetVersion,
        'riskLevel': riskLevel.name,
        'riskScore': riskScore,
        'totalFilesAffected': totalFilesAffected,
        'totalLocationsAffected': totalLocationsAffected,
        'impacts': impacts.map((e) => e.toJson()).toList(),
        'cascadingImpacts': cascadingImpacts.map((e) => e.toJson()).toList(),
        'warnings': warnings,
        'overallConfidence': overallConfidence,
      };
}

class BreakingChangeImpact {
  const BreakingChangeImpact({
    required this.breakingChange,
    required this.affectedLocations,
    this.suggestedFix,
  });

  final BreakingChange breakingChange;
  final List<CodeLocation> affectedLocations;
  final String? suggestedFix;

  Map<String, dynamic> toJson() => {
        'breakingChange': breakingChange.toJson(),
        'affectedLocations':
            affectedLocations.map((e) => e.toJson()).toList(),
        if (suggestedFix != null) 'suggestedFix': suggestedFix,
      };
}

class CodeLocation {
  const CodeLocation({
    required this.filePath,
    required this.line,
    required this.column,
    this.lineContent,
    this.surroundingContext,
    this.resolvedType,
  });

  final String filePath;
  final int line;
  final int column;
  final String? lineContent;
  final String? surroundingContext;
  final String? resolvedType;

  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'line': line,
        'column': column,
        if (lineContent != null) 'lineContent': lineContent,
        if (surroundingContext != null)
          'surroundingContext': surroundingContext,
        if (resolvedType != null) 'resolvedType': resolvedType,
      };
}

class CascadingImpact {
  const CascadingImpact({
    required this.dependencyName,
    required this.requiredBy,
    required this.currentConstraint,
    this.conflictReason,
  });

  final String dependencyName;
  final String requiredBy;
  final String currentConstraint;
  final String? conflictReason;

  Map<String, dynamic> toJson() => {
        'dependencyName': dependencyName,
        'requiredBy': requiredBy,
        'currentConstraint': currentConstraint,
        if (conflictReason != null) 'conflictReason': conflictReason,
      };
}
