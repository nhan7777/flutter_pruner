import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import '../dart/dart_ids.dart';

/// A standard generated GetIt wiring output discovered in the project.
///
/// The [path] and [dartNamespace] are intentionally report-safe: both are
/// stable across machines and contain no absolute filesystem path.
final class GeneratedWiringOutput {
  /// Creates evidence for one `*.config.dart` output candidate.
  const GeneratedWiringOutput({
    required this.path,
    required this.dartNamespace,
    required this.reason,
  });

  /// Project-relative candidate output path.
  final String path;

  /// Exact Dart library namespace for [path].
  final String dartNamespace;

  /// Stable explanation for why this output is protected.
  final String reason;
}

/// A source signal that could indicate unobserved generated GetIt wiring.
final class GeneratedWiringUncertainty {
  /// Creates a bounded generated-wiring uncertainty.
  const GeneratedWiringUncertainty({
    required this.source,
    required this.reason,
  });

  /// Project-relative evidence source, when a particular source is known.
  ///
  /// A null source means the project Dart-file listing itself was unavailable.
  final String? source;

  /// Stable, report-safe reason for the uncertainty.
  final String reason;
}

/// Immutable evidence used to protect generated Injectable/GetIt boundaries.
final class GeneratedWiringEvidence {
  /// Creates deterministic generated-wiring evidence.
  factory GeneratedWiringEvidence({
    required Iterable<GeneratedWiringOutput> outputs,
    required Iterable<GeneratedWiringUncertainty> uncertainties,
  }) {
    final outputByPath = <String, GeneratedWiringOutput>{
      for (final output in outputs) output.path: output,
    };
    final orderedOutputs = outputByPath.values.toList()
      ..sort((left, right) => left.path.compareTo(right.path));

    final uncertaintyByIdentity = <String, GeneratedWiringUncertainty>{
      for (final uncertainty in uncertainties)
        '${uncertainty.source ?? ''}\u0000${uncertainty.reason}': uncertainty,
    };
    final orderedUncertainties = uncertaintyByIdentity.values.toList()
      ..sort((left, right) {
        final sourceOrder = (left.source ?? '').compareTo(right.source ?? '');
        return sourceOrder != 0
            ? sourceOrder
            : left.reason.compareTo(right.reason);
      });

    return GeneratedWiringEvidence._(
      outputs: List<GeneratedWiringOutput>.unmodifiable(orderedOutputs),
      uncertainties: List<GeneratedWiringUncertainty>.unmodifiable(
        orderedUncertainties,
      ),
    );
  }

  const GeneratedWiringEvidence._({
    required this.outputs,
    required this.uncertainties,
  });

  /// Standard `*.config.dart` outputs, if any.
  final List<GeneratedWiringOutput> outputs;

  /// Dependency/import/annotation/filesystem evidence without a guaranteed
  /// generated output path.
  final List<GeneratedWiringUncertainty> uncertainties;

  /// Whether any generated wiring evidence was found.
  bool get hasGeneratedWiring => outputs.isNotEmpty || uncertainties.isNotEmpty;

  /// Stable, unique, project-relative evidence paths for reporting.
  List<String> get sources => List<String>.unmodifiable(
    {
      ...outputs.map((output) => output.path),
      ...uncertainties
          .map((uncertainty) => uncertainty.source)
          .whereType<String>(),
    }.toList()..sort(),
  );

  /// Exact Dart namespaces for observed generated output files only.
  List<String> get dartNamespaces => List<String>.unmodifiable(
    outputs.map((output) => output.dartNamespace).toSet().toList()..sort(),
  );
}

/// Allows tests and callers to supply a controlled project Dart-file listing.
typedef GeneratedWiringFileLister = Iterable<File> Function(ProjectContext);

/// Allows tests and callers to model unreadable or disappearing files.
typedef GeneratedWiringFileReader = String Function(File);

/// Finds conservative Injectable/GetIt generated-wiring boundaries.
///
/// This is a boundary probe, not a generated-registration parser. In
/// particular, it never infers which services a generated file registers.
final class GeneratedWiringProbe {
  GeneratedWiringProbe._();

  /// Inspects project Dart files and direct package metadata deterministically.
  static GeneratedWiringEvidence detect(
    ProjectContext project, {
    GeneratedWiringFileLister? files,
    GeneratedWiringFileReader? readFile,
  }) {
    final outputs = <GeneratedWiringOutput>[];
    final uncertainties = <GeneratedWiringUncertainty>[];

    _addDependencyEvidence(project, uncertainties);

    final lister = files ?? ((ProjectContext context) => context.dartFiles);
    final reader = readFile ?? ((File file) => file.readAsStringSync());
    List<File> orderedFiles;
    try {
      orderedFiles = lister(project).toList()
        ..sort(
          (left, right) => (_safeRelative(project, left) ?? '').compareTo(
            _safeRelative(project, right) ?? '',
          ),
        );
    } on FileSystemException {
      uncertainties.add(
        const GeneratedWiringUncertainty(
          source: null,
          reason: 'could not list project Dart files for generated wiring',
        ),
      );
      return GeneratedWiringEvidence(
        outputs: outputs,
        uncertainties: uncertainties,
      );
    } catch (_) {
      uncertainties.add(
        const GeneratedWiringUncertainty(
          source: null,
          reason: 'could not inspect project Dart files for generated wiring',
        ),
      );
      return GeneratedWiringEvidence(
        outputs: outputs,
        uncertainties: uncertainties,
      );
    }

    final seenPaths = <String>{};
    for (final file in orderedFiles) {
      final relative = _safeRelative(project, file);
      if (relative == null ||
          !seenPaths.add(relative) ||
          project.pathPolicy.shouldExclude(file.path)) {
        continue;
      }

      final isOutput = relative.endsWith('.config.dart');
      String contents;
      try {
        contents = reader(file);
      } on FileSystemException {
        if (isOutput) {
          outputs.add(
            _output(
              project,
              relative,
              'generated wiring candidate is unreadable',
            ),
          );
        } else {
          uncertainties.add(
            GeneratedWiringUncertainty(
              source: relative,
              reason:
                  'could not read Dart source while probing generated wiring',
            ),
          );
        }
        continue;
      } catch (_) {
        if (isOutput) {
          outputs.add(
            _output(
              project,
              relative,
              'generated wiring candidate is unavailable',
            ),
          );
        } else {
          uncertainties.add(
            GeneratedWiringUncertainty(
              source: relative,
              reason:
                  'could not inspect Dart source while probing generated wiring',
            ),
          );
        }
        continue;
      }

      if (isOutput) {
        outputs.add(
          _output(
            project,
            relative,
            'standard *.config.dart generated wiring output',
          ),
        );
        continue;
      }

      final parsed = parseString(content: contents, path: file.path);
      if (parsed.errors.isNotEmpty) {
        uncertainties.add(
          GeneratedWiringUncertainty(
            source: relative,
            reason:
                'could not parse Dart source while probing generated wiring',
          ),
        );
        continue;
      }

      final importsInjectable = _importsInjectable(parsed.unit);
      if (importsInjectable) {
        uncertainties.add(
          GeneratedWiringUncertainty(
            source: relative,
            reason: 'source imports Injectable APIs that may generate wiring',
          ),
        );
      }
      if (importsInjectable && _hasInjectableAnnotation(parsed.unit)) {
        uncertainties.add(
          GeneratedWiringUncertainty(
            source: relative,
            reason:
                'source uses an Injectable annotation that may generate wiring',
          ),
        );
      }
    }

    return GeneratedWiringEvidence(
      outputs: outputs,
      uncertainties: uncertainties,
    );
  }

  static void _addDependencyEvidence(
    ProjectContext project,
    List<GeneratedWiringUncertainty> uncertainties,
  ) {
    const packages = {'injectable', 'injectable_generator'};
    for (final package in packages) {
      for (final dependencyGroup in const [
        'dependencies',
        'dev_dependencies',
      ]) {
        if (!_hasDependency(project, dependencyGroup, package)) continue;
        uncertainties.add(
          GeneratedWiringUncertainty(
            source: 'pubspec.yaml',
            reason:
                'direct $package ${dependencyGroup == 'dependencies' ? 'dependency' : 'dev dependency'} may generate GetIt wiring',
          ),
        );
      }
    }
  }

  static GeneratedWiringOutput _output(
    ProjectContext project,
    String path,
    String reason,
  ) => GeneratedWiringOutput(
    path: path,
    dartNamespace: DartIds.libraryPath(project, project.resolve(path)),
    reason: reason,
  );

  static String? _safeRelative(ProjectContext project, File file) {
    final path = p.normalize(p.absolute(file.path));
    final root = p.normalize(p.absolute(project.root.path));
    if (!p.isWithin(root, path)) return null;
    return project.relative(path);
  }
}

bool _hasDependency(ProjectContext project, String group, String package) {
  final values = project.pubspec[group];
  return values is Map && values.containsKey(package);
}

bool _importsInjectable(CompilationUnit unit) => unit.directives
    .whereType<ImportDirective>()
    .map((directive) => directive.uri.stringValue)
    .any(
      (uri) =>
          uri != null &&
          (uri.startsWith('package:injectable/') ||
              uri.startsWith('package:injectable_generator/')),
    );

bool _hasInjectableAnnotation(CompilationUnit unit) {
  final visitor = _InjectableAnnotationVisitor();
  unit.accept(visitor);
  return visitor.found;
}

final class _InjectableAnnotationVisitor extends RecursiveAstVisitor<void> {
  static const _annotationNames = {
    'injectable',
    'singleton',
    'lazySingleton',
    'module',
    'InjectableInit',
    'preResolve',
    'factoryMethod',
  };

  bool found = false;

  @override
  void visitAnnotation(Annotation node) {
    final name = node.name.toSource().split('.').last;
    if (_annotationNames.contains(name)) found = true;
    super.visitAnnotation(node);
  }
}
