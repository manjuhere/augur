/// Models for breaking changes between package versions.
library;

enum Severity { critical, major, minor, info }

enum ChangeCategory {
  removal,
  rename,
  signatureChange,
  behaviorChange,
  deprecation,
  typeChange,
}

class BreakingChange {
  const BreakingChange({
    required this.id,
    required this.description,
    required this.severity,
    required this.category,
    this.affectedApi,
    this.replacement,
    this.migrationGuide,
    this.sourceUrl,
    this.confidence = 1.0,
  });

  final String id;
  final String description;
  final Severity severity;
  final ChangeCategory category;
  final String? affectedApi;
  final String? replacement;
  final String? migrationGuide;
  final String? sourceUrl;
  final double confidence;

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'severity': severity.name,
        'category': category.name,
        if (affectedApi != null) 'affectedApi': affectedApi,
        if (replacement != null) 'replacement': replacement,
        if (migrationGuide != null) 'migrationGuide': migrationGuide,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        'confidence': confidence,
      };
}
