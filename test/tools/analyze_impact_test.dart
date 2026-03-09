import 'package:test/test.dart';
import 'package:augur/models/analysis_result.dart';
import 'package:augur/models/breaking_change.dart';

void main() {
  group('AnalyzeImpactTool', () {
    group('risk level classification', () {
      test('low risk for score below 2.5', () {
        expect(_riskLevel(0.0), RiskLevel.low);
        expect(_riskLevel(1.0), RiskLevel.low);
        expect(_riskLevel(2.4), RiskLevel.low);
      });

      test('medium risk for score 2.5 to 5.0', () {
        expect(_riskLevel(2.5), RiskLevel.medium);
        expect(_riskLevel(3.0), RiskLevel.medium);
        expect(_riskLevel(4.9), RiskLevel.medium);
      });

      test('high risk for score 5.0 to 7.5', () {
        expect(_riskLevel(5.0), RiskLevel.high);
        expect(_riskLevel(6.0), RiskLevel.high);
        expect(_riskLevel(7.4), RiskLevel.high);
      });

      test('critical risk for score 7.5 and above', () {
        expect(_riskLevel(7.5), RiskLevel.critical);
        expect(_riskLevel(8.0), RiskLevel.critical);
        expect(_riskLevel(10.0), RiskLevel.critical);
      });
    });

    group('AnalysisResult model', () {
      test('creates with required fields', () {
        const result = AnalysisResult(
          packageName: 'provider',
          currentVersion: '6.0.5',
          targetVersion: '7.0.0',
          riskLevel: RiskLevel.high,
          riskScore: 6.5,
          totalFilesAffected: 10,
          totalLocationsAffected: 25,
          impacts: [],
          cascadingImpacts: [],
        );

        expect(result.packageName, 'provider');
        expect(result.currentVersion, '6.0.5');
        expect(result.targetVersion, '7.0.0');
        expect(result.riskLevel, RiskLevel.high);
        expect(result.riskScore, 6.5);
        expect(result.totalFilesAffected, 10);
        expect(result.totalLocationsAffected, 25);
        expect(result.warnings, isEmpty);
        expect(result.overallConfidence, 1.0);
      });

      test('toJson produces valid output', () {
        const result = AnalysisResult(
          packageName: 'provider',
          currentVersion: '6.0.5',
          targetVersion: '7.0.0',
          riskLevel: RiskLevel.high,
          riskScore: 6.5,
          totalFilesAffected: 10,
          totalLocationsAffected: 25,
          impacts: [],
          cascadingImpacts: [],
          warnings: ['Check manually'],
          overallConfidence: 0.85,
        );

        final json = result.toJson();
        expect(json['packageName'], 'provider');
        expect(json['riskLevel'], 'high');
        expect(json['riskScore'], 6.5);
        expect(json['warnings'], ['Check manually']);
        expect(json['overallConfidence'], 0.85);
      });
    });

    group('BreakingChangeImpact model', () {
      test('creates with required fields', () {
        const bc = BreakingChange(
          id: 'test_1',
          description: 'Removed deprecated API',
          severity: Severity.critical,
          category: ChangeCategory.removal,
        );

        const impact = BreakingChangeImpact(
          breakingChange: bc,
          affectedLocations: [
            CodeLocation(filePath: 'lib/main.dart', line: 10, column: 5),
          ],
          suggestedFix: 'Use the new API instead',
        );

        expect(impact.breakingChange.id, 'test_1');
        expect(impact.affectedLocations.length, 1);
        expect(impact.suggestedFix, 'Use the new API instead');
      });

      test('CodeLocation.toJson includes all fields', () {
        const loc = CodeLocation(
          filePath: 'lib/main.dart',
          line: 42,
          column: 8,
          lineContent: 'Provider.of<MyModel>(context)',
          resolvedType: 'MyModel',
        );

        final json = loc.toJson();
        expect(json['filePath'], 'lib/main.dart');
        expect(json['line'], 42);
        expect(json['column'], 8);
        expect(json['lineContent'], 'Provider.of<MyModel>(context)');
        expect(json['resolvedType'], 'MyModel');
      });
    });

    group('CascadingImpact model', () {
      test('creates and serializes correctly', () {
        const impact = CascadingImpact(
          dependencyName: 'nested_provider',
          requiredBy: 'provider',
          currentConstraint: '^6.0.0',
          conflictReason: 'Requires provider >=7.0.0',
        );

        expect(impact.dependencyName, 'nested_provider');
        expect(impact.requiredBy, 'provider');

        final json = impact.toJson();
        expect(json['conflictReason'], 'Requires provider >=7.0.0');
      });

      test('optional conflictReason excluded from JSON when null', () {
        const impact = CascadingImpact(
          dependencyName: 'nested_provider',
          requiredBy: 'provider',
          currentConstraint: '^6.0.0',
        );

        final json = impact.toJson();
        expect(json.containsKey('conflictReason'), isFalse);
      });
    });

    group('Severity enum', () {
      test('all severity levels exist', () {
        expect(Severity.values.length, 4);
        expect(Severity.values, contains(Severity.critical));
        expect(Severity.values, contains(Severity.major));
        expect(Severity.values, contains(Severity.minor));
        expect(Severity.values, contains(Severity.info));
      });
    });

    group('ChangeCategory enum', () {
      test('all categories exist', () {
        expect(ChangeCategory.values.length, 6);
        expect(ChangeCategory.values, contains(ChangeCategory.removal));
        expect(ChangeCategory.values, contains(ChangeCategory.rename));
        expect(ChangeCategory.values,
            contains(ChangeCategory.signatureChange));
        expect(ChangeCategory.values,
            contains(ChangeCategory.behaviorChange));
        expect(ChangeCategory.values,
            contains(ChangeCategory.deprecation));
        expect(ChangeCategory.values,
            contains(ChangeCategory.typeChange));
      });
    });
  });
}

/// Classify a numeric risk score into a [RiskLevel].
///
/// Thresholds: Low [0, 2.5), Medium [2.5, 5.0), High [5.0, 7.5), Critical [7.5, 10.0]
RiskLevel _riskLevel(double score) {
  if (score < 2.5) return RiskLevel.low;
  if (score < 5.0) return RiskLevel.medium;
  if (score < 7.5) return RiskLevel.high;
  return RiskLevel.critical;
}
