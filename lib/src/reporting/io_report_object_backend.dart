import 'dart:io';

import 'native/posix_report_object_backend.dart';
import 'native/windows_report_object_backend.dart';
import 'report_object_backend.dart';

/// Production host families accepted by immutable report persistence.
enum ReportHostPlatform {
  /// Linux hosts use the POSIX backend.
  linux,

  /// macOS hosts use the POSIX backend.
  macos,

  /// Windows hosts use the native Windows backend.
  windows,

  /// Every other host fails closed before analysis or apply mutation.
  unsupported,
}

/// Detects the current production host without exposing version details.
ReportHostPlatform currentReportHostPlatform() {
  if (Platform.isLinux) return ReportHostPlatform.linux;
  if (Platform.isMacOS) return ReportHostPlatform.macos;
  if (Platform.isWindows) return ReportHostPlatform.windows;
  return ReportHostPlatform.unsupported;
}

/// Selects the native backend for one explicitly recognized host family.
///
/// Factories remain injectable until the platform implementations install
/// their direct-FFI capabilities. Missing capabilities fail closed.
ReportObjectBackend createIoReportObjectBackend({
  ReportHostPlatform? hostPlatform,
  ReportObjectBackend Function()? posixFactory,
  ReportObjectBackend Function()? windowsFactory,
}) {
  final platform = hostPlatform ?? currentReportHostPlatform();
  final factory = switch (platform) {
    ReportHostPlatform.linux ||
    ReportHostPlatform.macos => posixFactory ?? PosixReportObjectBackend.new,
    ReportHostPlatform.windows =>
      windowsFactory ?? WindowsReportObjectBackend.new,
    ReportHostPlatform.unsupported => throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.unsupportedPlatform,
      operation: 'select-backend',
    ),
  };
  return factory();
}
