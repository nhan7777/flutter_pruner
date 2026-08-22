import '../../reporting/run_report.dart';

/// Formats a structured run report for output.
abstract class ReportFormatter {
  /// Creates a report formatter.
  const ReportFormatter();

  /// Formats [report] for output.
  String format(RunReport report);

  /// Writes [report] to [sink].
  ///
  /// Formatters that do not override this retain their existing string-based
  /// rendering behavior.
  void writeTo(RunReport report, StringSink sink) {
    sink.write(format(report));
  }
}
