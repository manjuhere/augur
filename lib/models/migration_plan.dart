/// Models for migration plans.
library;

enum StepType { pubspecChange, codeChange, runCommand, manual }

enum EffortLevel { trivial, low, medium, high }

class MigrationPlan {
  const MigrationPlan({
    required this.steps,
    required this.estimatedEffort,
    required this.effortDescription,
    this.prerequisites = const [],
    this.warnings = const [],
  });

  final List<MigrationStep> steps;
  final EffortLevel estimatedEffort;
  final String effortDescription;
  final List<String> prerequisites;
  final List<String> warnings;

  Map<String, dynamic> toJson() => {
        'steps': steps.map((e) => e.toJson()).toList(),
        'estimatedEffort': estimatedEffort.name,
        'effortDescription': effortDescription,
        'prerequisites': prerequisites,
        'warnings': warnings,
      };
}

class MigrationStep {
  const MigrationStep({
    required this.order,
    required this.type,
    required this.description,
    this.packageName,
    this.targetVersion,
    this.codeChanges,
    this.command,
  });

  final int order;
  final StepType type;
  final String description;
  final String? packageName;
  final String? targetVersion;
  final List<CodeChange>? codeChanges;
  final String? command;

  Map<String, dynamic> toJson() => {
        'order': order,
        'type': type.name,
        'description': description,
        if (packageName != null) 'packageName': packageName,
        if (targetVersion != null) 'targetVersion': targetVersion,
        if (codeChanges != null)
          'codeChanges': codeChanges!.map((e) => e.toJson()).toList(),
        if (command != null) 'command': command,
      };
}

class CodeChange {
  const CodeChange({
    required this.filePath,
    required this.line,
    required this.before,
    required this.after,
    this.explanation,
  });

  final String filePath;
  final int line;
  final String before;
  final String after;
  final String? explanation;

  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'line': line,
        'before': before,
        'after': after,
        if (explanation != null) 'explanation': explanation,
      };
}
