import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:test/test.dart';

void main() {
  group('ActionRiskScope', () {
    test('has expected values', () {
      expect(ActionRiskScope.values, hasLength(3));
      expect(
        ActionRiskScope.values,
        containsAll([
          ActionRiskScope.boundedSingle,
          ActionRiskScope.boundedFamily,
          ActionRiskScope.openEnded,
        ]),
      );
    });

    test('isFamily returns true only for boundedFamily', () {
      expect(ActionRiskScope.boundedSingle.isFamily, isFalse);
      expect(ActionRiskScope.boundedFamily.isFamily, isTrue);
      expect(ActionRiskScope.openEnded.isFamily, isFalse);
    });

    test('enum name serialization', () {
      expect(ActionRiskScope.boundedSingle.name, 'boundedSingle');
      expect(ActionRiskScope.boundedFamily.name, 'boundedFamily');
      expect(ActionRiskScope.openEnded.name, 'openEnded');
    });
  });
}
