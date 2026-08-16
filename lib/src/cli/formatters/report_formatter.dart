import '../../reporting/run_report.dart';

/// Formats a structured run report for output.
abstract class ReportFormatter {
  /// Formats [report] for output.
  String format(RunReport report);
}
