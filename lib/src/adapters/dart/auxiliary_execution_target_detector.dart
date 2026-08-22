import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../core/graph/execution_target.dart';
import '../../core/project/project_context.dart';

/// One fail-closed issue found while deriving an auxiliary context.
final class AuxiliaryExecutionTargetDetectionIssue {
  /// Creates a stable detector issue.
  const AuxiliaryExecutionTargetDetectionIssue({
    required this.code,
    required this.reason,
    required this.requiresGlobalBlocker,
  });

  /// Stable machine-readable issue code.
  final String code;

  /// Sanitized explanation.
  final String reason;

  /// Whether this issue must block actionability across the Dart namespace.
  final bool requiresGlobalBlocker;
}

/// One detected test or external auxiliary target.
final class AuxiliaryExecutionTargetDetection {
  /// Creates an immutable single-target detection.
  AuxiliaryExecutionTargetDetection({
    required this.target,
    List<AuxiliaryExecutionTargetDetectionIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);

  /// Explicit detected target.
  final AuxiliaryExecutionTarget target;

  /// Issues that make the target incomplete.
  final List<AuxiliaryExecutionTargetDetectionIssue> issues;
}

/// Runtime targets copied from every compatible configured target.
final class RuntimeAuxiliaryExecutionTargetDetection {
  /// Creates an immutable runtime-target detection.
  RuntimeAuxiliaryExecutionTargetDetection({
    required List<AuxiliaryExecutionTarget> targets,
    List<AuxiliaryExecutionTargetDetectionIssue> issues = const [],
  }) : targets = List.unmodifiable(targets),
       issues = List.unmodifiable(issues);

  /// Detected runtime targets.
  final List<AuxiliaryExecutionTarget> targets;

  /// Issues that make one or more targets incomplete.
  final List<AuxiliaryExecutionTargetDetectionIssue> issues;
}

/// Derives explicit test, runtime, and external execution environments.
final class AuxiliaryExecutionTargetDetector {
  /// Creates a detector for one immutable project pass.
  const AuxiliaryExecutionTargetDetector(this.project);

  /// Project whose target matrix supplies runtime environments.
  final ProjectContext project;

  /// Detects one test execution context from tracked source metadata.
  AuxiliaryExecutionTargetDetection detectTest({
    required String relativePath,
    ResolvedLibraryResult? library,
  }) {
    final filePlatforms = _testOnPlatforms(library);
    final projectPlatforms = _trackedProjectTestPlatforms();
    final effectivePlatforms = switch ((filePlatforms, projectPlatforms)) {
      (final file?, final configured?) => file.intersection(configured),
      (final file?, null) => file,
      (null, final configured?) => configured,
      _ => const <String>{},
    };
    if (effectivePlatforms.length == 1 && effectivePlatforms.single == 'vm') {
      return AuxiliaryExecutionTargetDetection(
        target: AuxiliaryExecutionTarget(
          id: 'aux:test:${_stablePathId(relativePath)}:vm',
          domain: AuxiliaryExecutionDomain.test,
          environmentValues: _sdkEnvironment(
            'vm',
            flutterUiAvailable: _hasFlutterSdk,
          ),
          environmentComplete: true,
          reason: 'test is explicitly constrained to the Dart VM',
        ),
      );
    }
    if (effectivePlatforms.length == 1 &&
        effectivePlatforms.single == 'browser') {
      return AuxiliaryExecutionTargetDetection(
        target: AuxiliaryExecutionTarget(
          id: 'aux:test:${_stablePathId(relativePath)}:browser',
          domain: AuxiliaryExecutionDomain.test,
          environmentValues: _sdkEnvironment(
            'web',
            flutterUiAvailable: _hasFlutterSdk,
          ),
          environmentComplete: true,
          reason: 'test is explicitly constrained to the browser',
        ),
      );
    }
    const issue = AuxiliaryExecutionTargetDetectionIssue(
      code: 'test-environment-incomplete',
      reason: 'test platform metadata does not close one supported environment',
      requiresGlobalBlocker: false,
    );
    return AuxiliaryExecutionTargetDetection(
      target: AuxiliaryExecutionTarget(
        id: 'aux:test:${_stablePathId(relativePath)}:incomplete',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {},
        environmentComplete: false,
        reason: issue.reason,
      ),
      issues: const [issue],
    );
  }

  /// Detects a standalone Dart executable whose launch environment is open.
  AuxiliaryExecutionTargetDetection detectExecutable(String relativePath) {
    const issue = AuxiliaryExecutionTargetDetectionIssue(
      code: 'executable-environment-incomplete',
      reason:
          'standalone executable environment is not closed by configured targets',
      requiresGlobalBlocker: false,
    );
    return AuxiliaryExecutionTargetDetection(
      target: AuxiliaryExecutionTarget(
        id: 'aux:runtime:executable:${_stablePathId(relativePath)}:incomplete',
        domain: AuxiliaryExecutionDomain.runtime,
        environmentValues: const {},
        environmentComplete: false,
        reason: issue.reason,
      ),
      issues: const [issue],
    );
  }

  /// Detects a runtime boundary whose originating execution context is open.
  AuxiliaryExecutionTargetDetection detectIncompleteRuntime({
    required String boundaryIdentity,
  }) {
    const issue = AuxiliaryExecutionTargetDetectionIssue(
      code: 'runtime-provenance-incomplete',
      reason:
          'runtime boundary caller provenance is not one exact build target',
      requiresGlobalBlocker: false,
    );
    return AuxiliaryExecutionTargetDetection(
      target: AuxiliaryExecutionTarget(
        id: 'aux:runtime:${_shortHash('$boundaryIdentity:open-provenance')}:incomplete',
        domain: AuxiliaryExecutionDomain.runtime,
        environmentValues: const {},
        environmentComplete: false,
        reason: issue.reason,
      ),
      issues: const [issue],
    );
  }

  /// Detects runtime contexts compatible with [capability].
  RuntimeAuxiliaryExecutionTargetDetection detectRuntime({
    required String callbackIdentity,
    required CallbackBoundaryCapability capability,
  }) {
    final compatible = project.targets
        .where((target) => _supports(capability, target.platform))
        .map(BuildTarget.snapshot)
        .toList();
    if (capability == CallbackBoundaryCapability.unknown ||
        compatible.isEmpty) {
      final code = capability == CallbackBoundaryCapability.unknown
          ? 'runtime-capability-unknown'
          : 'runtime-target-unavailable';
      final issue = AuxiliaryExecutionTargetDetectionIssue(
        code: code,
        reason: capability == CallbackBoundaryCapability.unknown
            ? 'callback capability could not be proven'
            : 'no configured target proves this callback can execute',
        requiresGlobalBlocker: true,
      );
      return RuntimeAuxiliaryExecutionTargetDetection(
        targets: [
          AuxiliaryExecutionTarget(
            id: 'aux:runtime:${_shortHash('$callbackIdentity:${capability.name}')}:incomplete',
            domain: AuxiliaryExecutionDomain.runtime,
            environmentValues: const {},
            environmentComplete: false,
            reason: issue.reason,
          ),
        ],
        issues: [issue],
      );
    }

    final targets = <AuxiliaryExecutionTarget>[];
    final issues = <AuxiliaryExecutionTargetDetectionIssue>[];
    for (final sourceTarget in compatible) {
      final environment = <String, String>{
        ..._sdkEnvironment(
          sourceTarget.platform,
          flutterUiAvailable: _hasFlutterSdk,
        ),
      };
      var complete = true;
      for (final define in sourceTarget.dartDefines.entries) {
        if (define.key.startsWith('dart.library.')) {
          if (environment[define.key] != define.value) {
            complete = false;
            issues.add(
              const AuxiliaryExecutionTargetDetectionIssue(
                code: 'reserved-environment-conflict',
                reason:
                    'a configured Dart define conflicts with an SDK-owned library value',
                requiresGlobalBlocker: true,
              ),
            );
          }
          continue;
        }
        environment[define.key] = define.value;
      }
      targets.add(
        AuxiliaryExecutionTarget(
          id:
              'aux:runtime:${_shortHash(callbackIdentity)}:'
              '${_shortHash(_targetIdentity(sourceTarget))}',
          domain: AuxiliaryExecutionDomain.runtime,
          environmentValues: environment,
          environmentComplete: complete,
          reason: complete
              ? 'callback runtime copied from a compatible configured target'
              : 'callback runtime contains conflicting environment metadata',
          sourceConfiguredTarget: sourceTarget,
        ),
      );
    }
    return RuntimeAuxiliaryExecutionTargetDetection(
      targets: targets,
      issues: issues,
    );
  }

  /// Detects an open external-consumer execution context.
  AuxiliaryExecutionTargetDetection detectExternal(String relativePath) {
    const issue = AuxiliaryExecutionTargetDetectionIssue(
      code: 'external-environment-open',
      reason: 'external consumer environments are not closed by this project',
      requiresGlobalBlocker: false,
    );
    return AuxiliaryExecutionTargetDetection(
      target: AuxiliaryExecutionTarget(
        id: 'aux:external:${_stablePathId(relativePath)}',
        domain: AuxiliaryExecutionDomain.external,
        environmentValues: const {},
        environmentComplete: false,
        reason: issue.reason,
      ),
      issues: const [issue],
    );
  }

  Set<String>? _normalizeTestSelector(String? selector) {
    if (selector == null) return null;
    final normalized = selector.trim().toLowerCase();
    if (normalized == 'vm') return const {'vm'};
    if (normalized == 'browser') return const {'browser'};
    return const {};
  }

  Set<String>? _testOnPlatforms(ResolvedLibraryResult? library) {
    if (library == null) return null;
    final candidates = <Annotation>[];
    for (final unit in library.units) {
      for (final directive in unit.unit.directives) {
        for (final annotation in directive.metadata) {
          if (_annotationName(annotation) == 'TestOn') {
            candidates.add(annotation);
          }
        }
      }
    }
    if (candidates.isEmpty) return null;
    if (candidates.length != 1) return const {};

    final annotation = candidates.single;
    if (annotation.parent is! LibraryDirective) return const {};
    final element = annotation.element;
    if (element is! ConstructorElement ||
        element.enclosingElement.name != 'TestOn' ||
        element.library.firstFragment.source.uri.toString() !=
            'package:test_api/src/backend/configuration/test_on.dart') {
      return const {};
    }
    final arguments = annotation.arguments?.arguments;
    if (arguments == null ||
        arguments.length != 1 ||
        arguments.single is! SimpleStringLiteral) {
      return const {};
    }
    final value = annotation.elementAnnotation?.computeConstantValue();
    if (value == null ||
        annotation.elementAnnotation?.constantEvaluationErrors?.isNotEmpty ==
            true) {
      return const {};
    }
    final selector = value.getField('expression')?.toStringValue();
    if (selector != (arguments.single as SimpleStringLiteral).value) {
      return const {};
    }
    return _normalizeTestSelector(selector) ?? const {};
  }

  Set<String>? _trackedProjectTestPlatforms() {
    final config = File(p.join(project.root.path, 'dart_test.yaml'));
    if (!config.existsSync()) return null;
    try {
      final yaml = loadYaml(config.readAsStringSync());
      if (yaml is! YamlMap) return const {};
      if (!yaml.containsKey('platforms')) return null;
      final rawPlatforms = yaml['platforms'];
      if (rawPlatforms is! YamlList || rawPlatforms.isEmpty) return const {};
      final normalized = <String>{};
      for (final raw in rawPlatforms) {
        final platform = raw.toString().trim().toLowerCase();
        if (platform == 'vm') {
          normalized.add('vm');
        } else if (const {
          'browser',
          'chrome',
          'firefox',
          'safari',
        }.contains(platform)) {
          normalized.add('browser');
        } else {
          return const {};
        }
      }
      return Set.unmodifiable(normalized);
    } on Object {
      return const {};
    }
  }

  bool get _hasFlutterSdk {
    for (final sectionName in const ['dependencies', 'dev_dependencies']) {
      final section = project.pubspec[sectionName];
      if (section is! Map) continue;
      for (final packageName in const ['flutter', 'flutter_test']) {
        final dependency = section[packageName];
        if (dependency is Map && dependency['sdk'] == 'flutter') return true;
      }
    }
    return false;
  }

  bool _supports(CallbackBoundaryCapability capability, String platform) {
    const nativePlatforms = {'android', 'ios', 'macos', 'linux', 'windows'};
    return switch (capability) {
      CallbackBoundaryCapability.workmanagerMobile => const {
        'android',
        'ios',
      }.contains(platform),
      CallbackBoundaryCapability.dartVm ||
      CallbackBoundaryCapability.flutterEngineNative ||
      CallbackBoundaryCapability.ffiNative => nativePlatforms.contains(
        platform,
      ),
      CallbackBoundaryCapability.unknown => false,
    };
  }
}

Map<String, String> _sdkEnvironment(
  String platform, {
  required bool flutterUiAvailable,
}) {
  final web = platform == 'web' || platform == 'browser';
  return Map.unmodifiable({
    'dart.library.io': web ? 'false' : 'true',
    'dart.library.html': web ? 'true' : 'false',
    'dart.library.js_interop': web ? 'true' : 'false',
    'dart.library.ui': flutterUiAvailable ? 'true' : 'false',
  });
}

String _annotationName(Annotation annotation) => switch (annotation.name) {
  SimpleIdentifier(:final name) => name,
  PrefixedIdentifier(:final identifier) => identifier.name,
};

String _stablePathId(String path) {
  final normalized = path.replaceAll('\\', '/');
  final sanitized = normalized.replaceAll(RegExp(r'[^A-Za-z0-9._/-]'), '_');
  return sanitized == normalized
      ? sanitized
      : '$sanitized~${_shortHash(normalized)}';
}

String _targetIdentity(BuildTarget target) => jsonEncode({
  'name': target.name,
  'platform': target.platform,
  'flavor': target.flavor,
  'entrypoint': target.entrypoint,
  'dartDefines': Map.fromEntries(
    target.dartDefines.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key)),
  ),
});

String _shortHash(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 16);
