import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:test/test.dart';

void main() {
  group('L10nMutationSelection', () {
    test('exact selection with no expansion', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title'},
        findingIdToKey: {'l10n:app.title': 'title'},
      );

      expect(selection.requestedFindingIds, {'l10n:app.title'});
      expect(selection.effectiveFindingIds, {'l10n:app.title'});
      expect(selection.expandedFindingIds, isEmpty);
      expect(selection.requestedKeys, {'title'});
      expect(selection.effectiveKeys, {'title'});
      expect(selection.hasExpansion, isFalse);
    });

    test('exact selection validates successfully', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title', 'l10n:app.subtitle'},
        effectiveFindingIds: {'l10n:app.title', 'l10n:app.subtitle'},
        findingIdToKey: {
          'l10n:app.title': 'title',
          'l10n:app.subtitle': 'subtitle',
        },
      );

      expect(() => selection.validate(), returnsNormally);
    });

    test('selection with dependency expansion', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title', 'l10n:app.relatedKey'},
        findingIdToKey: {
          'l10n:app.title': 'title',
          'l10n:app.relatedKey': 'relatedKey',
        },
        expansionReasons: {
          'l10n:app.relatedKey': 'Required by planner for atomicity',
        },
      );

      expect(selection.requestedFindingIds, {'l10n:app.title'});
      expect(selection.effectiveFindingIds, {
        'l10n:app.title',
        'l10n:app.relatedKey',
      });
      expect(selection.expandedFindingIds, {'l10n:app.relatedKey'});
      expect(selection.requestedKeys, {'title'});
      expect(selection.effectiveKeys, {'title', 'relatedKey'});
      expect(selection.hasExpansion, isTrue);
    });

    test('expansion requires reasons for all expanded findings', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title', 'l10n:app.other'},
        findingIdToKey: {'l10n:app.title': 'title', 'l10n:app.other': 'other'},
        expansionReasons: {}, // Missing reason
      );

      expect(() => selection.validate(), throwsA(isA<ArgumentError>()));
    });

    test('validates requested is subset of effective', () {
      expect(
        () => L10nMutationSelection(
          requestedFindingIds: {'l10n:app.title', 'l10n:app.missing'},
          effectiveFindingIds: {'l10n:app.title'},
          findingIdToKey: {'l10n:app.title': 'title'},
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('validates all effective findings have key mapping', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title', 'l10n:app.unmapped'},
        findingIdToKey: {'l10n:app.title': 'title'},
        expansionReasons: {'l10n:app.unmapped': 'Added by planner'},
      );

      expect(() => selection.validate(), throwsA(isA<ArgumentError>()));
    });

    test('expansion reasons only for expanded findings', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title'},
        findingIdToKey: {'l10n:app.title': 'title'},
        expansionReasons: {
          'l10n:app.title': 'This is a requested finding, not expanded',
        },
      );

      expect(() => selection.validate(), throwsA(isA<ArgumentError>()));
    });

    test('requestedKeys derives from findingIdToKey', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.key1', 'l10n:app.key2'},
        effectiveFindingIds: {'l10n:app.key1', 'l10n:app.key2'},
        findingIdToKey: {
          'l10n:app.key1': 'firstKey',
          'l10n:app.key2': 'secondKey',
        },
      );

      expect(selection.requestedKeys, {'firstKey', 'secondKey'});
    });

    test('effectiveKeys includes all keys', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.key1'},
        effectiveFindingIds: {'l10n:app.key1', 'l10n:app.key2'},
        findingIdToKey: {
          'l10n:app.key1': 'firstKey',
          'l10n:app.key2': 'secondKey',
        },
        expansionReasons: {'l10n:app.key2': 'Dependency'},
      );

      expect(selection.effectiveKeys, {'firstKey', 'secondKey'});
    });

    test('equality works correctly', () {
      final selection1 = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title'},
        findingIdToKey: {'l10n:app.title': 'title'},
      );

      final selection2 = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title'},
        effectiveFindingIds: {'l10n:app.title'},
        findingIdToKey: {'l10n:app.title': 'title'},
      );

      final selection3 = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.other'},
        effectiveFindingIds: {'l10n:app.other'},
        findingIdToKey: {'l10n:app.other': 'other'},
      );

      expect(selection1, equals(selection2));
      expect(selection1, isNot(equals(selection3)));
    });

    test('handles empty key mapping gracefully', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.missing'},
        effectiveFindingIds: {'l10n:app.missing'},
        findingIdToKey: {}, // No mapping
      );

      // Keys will be empty since no mapping exists
      expect(selection.requestedKeys, isEmpty);
      expect(selection.effectiveKeys, isEmpty);

      // But validation should fail
      expect(() => selection.validate(), throwsA(isA<ArgumentError>()));
    });
  });
}
