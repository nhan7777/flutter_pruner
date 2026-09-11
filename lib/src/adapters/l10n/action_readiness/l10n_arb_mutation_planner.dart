import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'arb_document.dart';
import 'immutable_bytes.dart';
import 'l10n_evidence_failure.dart';

const _planningStage = 'arb-mutation-planning';

/// One top-level ARB member removed from its original byte snapshot.
final class ArbRemoval {
  /// Creates removal evidence for [decodedKey] at [span].
  const ArbRemoval({required this.decodedKey, required this.span});

  /// The JSON-decoded member key.
  final String decodedKey;

  /// The exact member token span in the original document.
  final ByteSpan span;
}

/// Result of planning one atomic ARB-family mutation.
sealed class L10nArbMutationPlanResult {
  const L10nArbMutationPlanResult();
}

/// A family mutation that passed all byte and semantic postconditions.
final class L10nArbMutationPlanReady extends L10nArbMutationPlanResult {
  /// Creates a ready result for [plan].
  const L10nArbMutationPlanReady(this.plan);

  /// The complete atomic family plan.
  final L10nArbMutationPlan plan;
}

/// A whole-family rejection with stable structured identities.
final class L10nArbMutationPlanRejected extends L10nArbMutationPlanResult {
  /// Creates a rejected result for immutable [failures].
  const L10nArbMutationPlanRejected(this.failures);

  /// Deterministically ordered reasons why no family plan was produced.
  final List<L10nEvidenceFailure> failures;
}

/// Immutable candidate bytes and original-source removal evidence for a family.
final class L10nArbMutationPlan {
  L10nArbMutationPlan._({
    required this.candidateArbBytes,
    required this.removalsByPath,
    required this.mutationFingerprint,
  });

  /// Candidate bytes for every family document, sorted by relative path.
  final Map<String, ImmutableBytes> candidateArbBytes;

  /// Removed member tokens for every family document, sorted by relative path.
  final Map<String, List<ArbRemoval>> removalsByPath;

  /// SHA-256 identity of the original family, selection, and planned edits.
  final String mutationFingerprint;
}

/// Plans byte-exact removal of selected messages across one ARB family.
final class L10nArbMutationPlanner {
  const L10nArbMutationPlanner._();

  /// Plans one all-or-nothing family edit without mutating source documents.
  static L10nArbMutationPlanResult plan({
    required String templatePath,
    required Map<String, ArbDocument> documentsByPath,
    required Iterable<String> selectedKeys,
  }) {
    final selection = <String>[];
    final seenSelection = <String>{};
    final selectionFailures = <L10nEvidenceFailure>[];
    for (final decodedKey in selectedKeys) {
      selection.add(decodedKey);
      if (decodedKey.isEmpty) {
        selectionFailures.add(
          _failure(
            L10nEvidenceRejectionCode.invalidSelection,
            'selection-key-empty',
          ),
        );
      }
      if (decodedKey.startsWith('@')) {
        selectionFailures.add(
          _failure(
            L10nEvidenceRejectionCode.invalidSelection,
            'selection-key-pseudo',
          ),
        );
      }
      if (!seenSelection.add(decodedKey)) {
        selectionFailures.add(
          _failure(
            L10nEvidenceRejectionCode.invalidSelection,
            'selection-key-duplicate',
          ),
        );
      }
    }
    if (selection.isEmpty) {
      selectionFailures.add(
        _failure(L10nEvidenceRejectionCode.invalidSelection, 'selection-empty'),
      );
    }
    if (selectionFailures.isNotEmpty) {
      return _rejected(selectionFailures);
    }

    final selectedSet = Set<String>.unmodifiable(seenSelection);
    final sortedDocuments = SplayTreeMap<String, ArbDocument>()
      ..addAll(documentsByPath);
    if (!sortedDocuments.containsKey(templatePath)) {
      return _rejected([
        _failure(
          L10nEvidenceRejectionCode.arbFamilyIncomplete,
          'template-document-missing',
          relativePath: templatePath,
        ),
      ]);
    }

    final verifiedDocuments = SplayTreeMap<String, ArbDocument>();
    final parseFailures = <L10nEvidenceFailure>[];
    for (final entry in sortedDocuments.entries) {
      final reparsed = ArbDocument.parse(entry.value.source.copy());
      if (reparsed is ArbParseFailure) {
        parseFailures.add(
          _failure(
            L10nEvidenceRejectionCode.arbParseFailure,
            'document-parse-failed',
            relativePath: entry.key,
          ),
        );
      } else {
        verifiedDocuments[entry.key] = (reparsed as ArbParseSuccess).document;
      }
    }
    if (parseFailures.isNotEmpty) return _rejected(parseFailures);

    final template = verifiedDocuments[templatePath]!;
    final templateMessages = _messageKeys(template);
    final missingSelections = selection
        .where((key) => !templateMessages.contains(key))
        .map(
          (_) => _failure(
            L10nEvidenceRejectionCode.invalidSelection,
            'selected-template-message-missing',
            relativePath: templatePath,
          ),
        )
        .toList(growable: false);
    if (missingSelections.isNotEmpty) return _rejected(missingSelections);

    final familyFailures = _familySemanticFailures(
      templatePath: templatePath,
      documentsByPath: verifiedDocuments,
      code: L10nEvidenceRejectionCode.arbFamilyIncomplete,
    );
    if (familyFailures.isNotEmpty) return _rejected(familyFailures);

    final candidates = SplayTreeMap<String, ImmutableBytes>();
    final removalsByPath = SplayTreeMap<String, List<ArbRemoval>>();
    final candidateDocuments = SplayTreeMap<String, ArbDocument>();
    final editFailures = <L10nEvidenceFailure>[];

    for (final entry in verifiedDocuments.entries) {
      final path = entry.key;
      final document = entry.value;
      final removalMembers = <ArbMember>[
        for (final member in document.members)
          if (_isSelectedMember(member.decodedKey, selectedSet)) member,
      ];
      final removalKeys = <String>{
        for (final member in removalMembers) member.decodedKey,
      };
      final edit = document.removeMembers(removalKeys);
      if (edit is ArbDocumentEditRejected) {
        editFailures.add(
          _failure(
            L10nEvidenceRejectionCode.editPostconditionFailed,
            'document-edit-rejected',
            relativePath: path,
          ),
        );
        continue;
      }

      final ready = edit as ArbDocumentEditReady;
      final candidateParse = ArbDocument.parse(ready.bytes.copy());
      if (candidateParse is ArbParseFailure) {
        editFailures.add(
          _failure(
            L10nEvidenceRejectionCode.arbParseFailure,
            'candidate-document-parse-failed',
            relativePath: path,
          ),
        );
        continue;
      }

      final candidate = (candidateParse as ArbParseSuccess).document;
      editFailures.addAll(
        _documentPostconditionFailures(
          path: path,
          original: document,
          candidate: candidate,
          selectedKeys: selectedSet,
          removalKeys: removalKeys,
        ),
      );
      candidates[path] = ready.bytes;
      candidateDocuments[path] = candidate;
      removalsByPath[path] = List<ArbRemoval>.unmodifiable([
        for (final member in removalMembers)
          ArbRemoval(decodedKey: member.decodedKey, span: member.memberSpan),
      ]);
    }
    if (editFailures.isNotEmpty) return _rejected(editFailures);

    final candidateFamilyFailures = _familySemanticFailures(
      templatePath: templatePath,
      documentsByPath: candidateDocuments,
      code: L10nEvidenceRejectionCode.editPostconditionFailed,
    );
    if (candidateFamilyFailures.isNotEmpty) {
      return _rejected(candidateFamilyFailures);
    }

    final immutableCandidates = UnmodifiableMapView<String, ImmutableBytes>(
      candidates,
    );
    final immutableRemovals = UnmodifiableMapView<String, List<ArbRemoval>>(
      removalsByPath,
    );
    return L10nArbMutationPlanReady(
      L10nArbMutationPlan._(
        candidateArbBytes: immutableCandidates,
        removalsByPath: immutableRemovals,
        mutationFingerprint: _fingerprint(
          templatePath: templatePath,
          selectedKeys: selectedSet,
          originalDocuments: verifiedDocuments,
          candidates: candidates,
          removalsByPath: removalsByPath,
        ),
      ),
    );
  }
}

bool _isSelectedMember(String decodedKey, Set<String> selectedKeys) {
  if (selectedKeys.contains(decodedKey)) return true;
  return decodedKey.startsWith('@') &&
      !decodedKey.startsWith('@@') &&
      selectedKeys.contains(decodedKey.substring(1));
}

Set<String> _messageKeys(ArbDocument document) => {
  for (final member in document.members)
    if (!member.decodedKey.startsWith('@')) member.decodedKey,
};

List<L10nEvidenceFailure> _familySemanticFailures({
  required String templatePath,
  required Map<String, ArbDocument> documentsByPath,
  required L10nEvidenceRejectionCode code,
}) {
  final failures = <L10nEvidenceFailure>[];
  final templateMessages = _messageKeys(documentsByPath[templatePath]!);
  for (final entry in documentsByPath.entries) {
    final path = entry.key;
    final document = entry.value;
    final messages = _messageKeys(document);

    final locale = document.member('@@locale');
    if (locale != null &&
        (locale.decodedValue is! String ||
            (locale.decodedValue! as String).isEmpty)) {
      failures.add(
        _failure(code, 'locale-identity-ambiguous', relativePath: path),
      );
    }

    for (final member in document.members) {
      final key = member.decodedKey;
      if (key.startsWith('@') &&
          !key.startsWith('@@') &&
          !messages.contains(key.substring(1))) {
        failures.add(
          _failure(code, 'orphan-message-metadata', relativePath: path),
        );
      }
    }

    if (path == templatePath) continue;
    for (final message in messages) {
      if (!templateMessages.contains(message)) {
        failures.add(_failure(code, 'locale-only-message', relativePath: path));
      }
    }
  }
  return failures;
}

List<L10nEvidenceFailure> _documentPostconditionFailures({
  required String path,
  required ArbDocument original,
  required ArbDocument candidate,
  required Set<String> selectedKeys,
  required Set<String> removalKeys,
}) {
  final failures = <L10nEvidenceFailure>[];
  for (final selectedKey in selectedKeys) {
    if (candidate.member(selectedKey) != null ||
        candidate.member('@$selectedKey') != null) {
      failures.add(
        _failure(
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'selected-member-remains',
          relativePath: path,
        ),
      );
    }
  }

  for (final member in original.members) {
    if (removalKeys.contains(member.decodedKey)) continue;
    final surviving = candidate.member(member.decodedKey);
    if (surviving == null ||
        !original.source
            .slice(member.memberSpan)
            .contentEquals(candidate.source.slice(surviving.memberSpan))) {
      failures.add(
        _failure(
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'unselected-member-changed',
          relativePath: path,
        ),
      );
    }
  }

  final originalLocale = original.member('@@locale');
  final candidateLocale = candidate.member('@@locale');
  if ((originalLocale == null) != (candidateLocale == null) ||
      (originalLocale != null &&
          candidateLocale != null &&
          originalLocale.decodedValue != candidateLocale.decodedValue)) {
    failures.add(
      _failure(
        L10nEvidenceRejectionCode.editPostconditionFailed,
        'locale-identity-changed',
        relativePath: path,
      ),
    );
  }
  return failures;
}

String _fingerprint({
  required String templatePath,
  required Set<String> selectedKeys,
  required Map<String, ArbDocument> originalDocuments,
  required Map<String, ImmutableBytes> candidates,
  required Map<String, List<ArbRemoval>> removalsByPath,
}) {
  final sortedSelection = selectedKeys.toList(growable: false)..sort();
  final canonical = <String, Object?>{
    'templatePath': templatePath,
    'selectedKeys': sortedSelection,
    'documents': [
      for (final path in originalDocuments.keys)
        <String, Object?>{
          'path': path,
          'originalSha256': originalDocuments[path]!.source.sha256Hex,
          'candidateSha256': candidates[path]!.sha256Hex,
          'removals': [
            for (final removal in removalsByPath[path]!)
              <String, Object?>{
                'decodedKey': removal.decodedKey,
                'start': removal.span.start,
                'endExclusive': removal.span.endExclusive,
              },
          ],
        },
    ],
  };
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

L10nEvidenceFailure _failure(
  L10nEvidenceRejectionCode code,
  String detailCode, {
  String? relativePath,
}) => L10nEvidenceFailure(
  code: code,
  stage: _planningStage,
  detailCode: detailCode,
  relativePath: relativePath,
);

L10nArbMutationPlanRejected _rejected(Iterable<L10nEvidenceFailure> failures) {
  final ordered = failures.toList(growable: false)..sort(_compareFailures);
  return L10nArbMutationPlanRejected(List.unmodifiable(ordered));
}

int _compareFailures(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  final code = left.code.index.compareTo(right.code.index);
  if (code != 0) return code;
  final stage = left.stage.compareTo(right.stage);
  if (stage != 0) return stage;
  final path = (left.relativePath ?? '').compareTo(right.relativePath ?? '');
  if (path != 0) return path;
  return left.detailCode.compareTo(right.detailCode);
}
