import 'package:meta/meta.dart';

/// Explicit no-resolution verification policy for l10n mutations.
@immutable
final class L10nVerificationPolicy {
  /// Creates a verification policy using the given Flutter executable.
  const L10nVerificationPolicy({required this.flutterBinaryPath});

  /// Path or executable name used to run Flutter verification commands.
  final String flutterBinaryPath;

  /// Default l10n verification: no dependency resolution
  static const List<String> defaultAnalyzeCommand = [
    'analyze',
    '--no-pub',
    '--fatal-infos',
  ];

  /// Default l10n test command without dependency resolution.
  static const List<String> defaultTestCommand = ['test', '--no-pub'];

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
      final analyzeRequiresResolution =
          analyzeCommand.contains('pub') &&
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
  /// The commands satisfy the no-resolution contract.
  accepted,

  /// A command does not declare the no-resolution contract.
  rejectedNoContract,

  /// A command explicitly requires dependency resolution.
  rejectedResolutionRequired,
}
