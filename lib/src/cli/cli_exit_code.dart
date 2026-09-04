/// Stable process exit codes for the public CLI contract.
abstract final class CliExitCode {
  /// The command completed, including deliberate user cancellation.
  static const success = 0;

  /// The invocation was valid but the requested operation could not complete.
  static const operationalFailure = 1;

  /// The command stopped without mutation because reviewed evidence was stale.
  static const safeStopped = 2;

  /// The invocation itself was invalid.
  static const usage = 64;

  /// An unexpected uncaught error escaped command handling.
  static const internal = 70;
}
