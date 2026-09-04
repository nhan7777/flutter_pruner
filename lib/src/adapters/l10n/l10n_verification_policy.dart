import 'package:meta/meta.dart';

/// Explicit no-resolution verification policy for l10n mutations.
@immutable
final class L10nVerificationPolicy {
  const L10nVerificationPolicy({
    required this.flutterBinaryPath,
  });

  final String flutterBinaryPath;

  /// Default l10n verification: no dependency resolution
  static const List<String> defaultAnalyzeCommand = [
    'analyze',
    '--no-pub',
    '--fatal-infos',
  ];

  static const List<String> defaultTestCommand = [
    'test',
    '--no-pub',
  ];

  /// Validate that project verification override has no-resolution contract
  static bool hasNoResolutionContract(List<String> command) {
    return command.contains('--no-pub') || command.contains('--no-deps');
  }

  /// Validates custom analyze and test commands for no-resolution contract.
  static VerificationPolicyValidation validateOverride({
    required List<String> analyzeCommand,
    required List<String> testCommand,
  }) {
    final analyzeHasContract = hasNoResolutionContract(analyzeCommand);
    final testHasContract = hasNoResolutionContract(testCommand);

    if (!analyzeHasContract || !testHasContract) {
      // Check if commands explicitly require resolution
      final analyzeRequiresResolution = analyzeCommand.contains('pub') &&
          !analyzeCommand.contains('--no-pub');
      final testRequiresResolution =
          testCommand.contains('pub') && !testCommand.contains('--no-pub');

      if (analyzeRequiresResolution || testRequiresResolution) {
        return VerificationPolicyValidation.rejectedResolutionRequired;
      }

      return VerificationPolicyValidation.rejectedNoContract;
    }

    return VerificationPolicyValidation.accepted;
  }
}

/// Result of verification policy validation.
enum VerificationPolicyValidation {
  accepted,
  rejectedNoContract,
  rejectedResolutionRequired,
}
