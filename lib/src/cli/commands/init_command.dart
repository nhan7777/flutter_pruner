import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../core/graph/build_condition.dart';
import '../../core/project/project_config.dart';
import '../../core/project/project_source_path.dart';
import '../../core/project/tool_workspace.dart';
import '../cli_exit_code.dart';
import '../init_prompt.dart';
import '../init_target_discovery.dart';
import '../project_command_support.dart';
import '../usage_error.dart';

/// Creates a project-local Flutter Pruner configuration.
class InitCommand extends Command<int> {
  /// Creates the `init` command.
  InitCommand({InitPrompt prompt = const StdioInitPrompt()})
    : _prompt = prompt {
    argParser
      ..addOption(
        'type',
        allowed: ['application', 'package', 'package-internal'],
        help: 'Project shape; defaults to conservative filesystem detection',
      )
      ..addMultiOption(
        'entrypoint',
        help:
            'Entrypoint relative to the project; may be passed more than once',
      )
      ..addMultiOption(
        'platform',
        allowed: _supportedPlatforms,
        help: 'Target platform; may be passed more than once',
      )
      ..addFlag(
        'complete',
        negatable: false,
        help: 'Assert every supported build target is declared',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace existing Flutter Pruner configuration',
      )
      ..addFlag(
        'interactive',
        defaultsTo: true,
        help: 'Ask questions when attached to a terminal',
      )
      ..addFlag(
        'yes',
        negatable: false,
        help:
            'Accept conservative detected defaults without prompting; does '
            'not assert complete coverage',
      );
    addProjectOption(argParser);
  }

  static const _supportedPlatforms = [
    'android',
    'ios',
    'web',
    'macos',
    'linux',
    'windows',
  ];

  final InitPrompt _prompt;

  @override
  String get invocation => '${super.invocation} [project-path]';

  @override
  String get name => 'init';

  @override
  String get description =>
      'Create a conservative project-local Flutter Pruner configuration';

  @override
  String get usageFooter => '''Examples:
  flutter_pruner init
  flutter_pruner init --project ./example

Writes configuration and .gitignore''';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length > 1) {
      throw commandUsageError(this, 'Expected at most one project path.');
    }
    if (args.option('project') != null && args.rest.isNotEmpty) {
      throw commandUsageError(
        this,
        'Pass the project once, using either --project or [project-path].',
      );
    }
    final shapingFlags =
        args.wasParsed('type') ||
        args.wasParsed('entrypoint') ||
        args.wasParsed('platform') ||
        args.flag('complete');
    if (args.wasParsed('interactive') &&
        args.flag('interactive') &&
        shapingFlags) {
      throw commandUsageError(
        this,
        '--interactive cannot be combined with --type, --entrypoint, --platform, or --complete. Use the wizard or explicit flags.',
      );
    }
    if (args.wasParsed('interactive') &&
        args.flag('interactive') &&
        args.flag('yes')) {
      throw commandUsageError(
        this,
        '--interactive cannot be combined with --yes. Choose the wizard or conservative automatic defaults.',
      );
    }
    if (args.wasParsed('interactive') &&
        args.flag('interactive') &&
        !_prompt.isInteractive) {
      throw commandUsageError(
        this,
        '--interactive requires an attached terminal. Use --no-interactive for scripts and CI.',
      );
    }

    late final ToolWorkspace workspace;
    try {
      workspace = resolveToolWorkspace(
        args,
        positionalProjectPath: args.rest.isEmpty ? null : args.rest.single,
      );
    } on ProjectSelectionException catch (error) {
      stderr.writeln('Error: $error');
      return CliExitCode.operationalFailure;
    }

    final pubspecFile = File(
      p.join(workspace.projectRoot.path, 'pubspec.yaml'),
    );
    final packageName = await _readPackageName(pubspecFile);
    if (packageName == null) return 1;

    final isHybridProject = _isHybridProject(
      workspace.projectRoot,
      packageName,
    );
    final explicitType = args.option('type');
    final detectedType = _detectType(workspace.projectRoot, packageName);
    final useWizard =
        args.flag('interactive') &&
        _prompt.isInteractive &&
        !shapingFlags &&
        !args.flag('yes');

    var force = args.flag('force');
    final existingConfig = workspace.configFile.existsSync()
        ? workspace.configFile
        : workspace.legacyConfigFile.existsSync()
        ? workspace.legacyConfigFile
        : null;
    if (existingConfig != null && !force) {
      if (!useWizard) {
        stderr.writeln(
          'Error: configuration already exists at ${existingConfig.path}. '
          'Use --force to replace it.',
        );
        return 1;
      }
      try {
        final replace = InitQuestions(_prompt, styled: true).yesNo(
          'Configuration exists at ${existingConfig.path}. Replace it?',
          defaultValue: false,
        );
        if (!replace) {
          _InitWizardPresentation(_prompt).warning('Cancelled.');
          return CliExitCode.success;
        }
        force = true;
      } on InitCancelledException {
        _InitWizardPresentation(_prompt).warning('Cancelled.');
        return CliExitCode.success;
      }
    }

    late final _InitDraft draft;
    try {
      if (useWizard) {
        draft = _buildInteractiveDraft(
          workspace: workspace,
          pubspecFile: pubspecFile,
          packageName: packageName,
          detectedType: detectedType,
          isHybridProject: isHybridProject,
        );
      } else {
        final projectType = explicitType ?? detectedType;
        if (projectType == null) {
          stderr.writeln(
            'Error: could not detect a project type. Expected lib/main.dart '
            'or lib/$packageName.dart; pass --type to choose explicitly.',
          );
          return 1;
        }
        draft = _buildNonInteractiveDraft(
          args: args,
          workspace: workspace,
          pubspecFile: pubspecFile,
          packageName: packageName,
          projectType: projectType,
          isHybridProject: isHybridProject,
        );
      }
    } on InitCancelledException {
      _InitWizardPresentation(_prompt).warning('Cancelled.');
      return CliExitCode.success;
    } on ProjectSourcePathException catch (error) {
      throw commandUsageError(this, error.message);
    } on FormatException catch (error) {
      throw commandUsageError(this, error.message);
    }

    if (isHybridProject &&
        draft.projectType == 'application' &&
        draft.complete) {
      throw commandUsageError(
        this,
        'Application mode cannot assert complete coverage for a hybrid project with a public package surface. Use package or package-internal.',
      );
    }

    final config = _renderConfig(
      projectType: draft.projectType,
      publicEntrypoints: draft.publicEntrypoints,
      targets: draft.targets,
      complete: draft.complete,
      verification: draft.verification,
    );

    await _writeConfigAtomically(workspace, config, preserveBackup: force);
    final gitignore = File(p.join(workspace.directory.path, '.gitignore'));
    if (!gitignore.existsSync()) await gitignore.writeAsString(_gitignore);
    if (useWizard) {
      _writeInteractiveCompletion(workspace, draft);
    } else {
      stdout.writeln('Created ${workspace.configFile.path}');
      stdout.writeln('Detected ${draft.projectType}.');
      if (draft.projectType == 'package') {
        stdout.writeln(
          'Reusable-package consumers are open-world. Findings stay capped '
          'at REVIEW regardless of target completeness.',
        );
      } else if (draft.projectType == 'package-internal') {
        stdout.writeln(
          'Package-internal mode excludes external consumers. Scan and apply '
          'will display a persistent warning. Target coverage is '
          '${draft.complete ? 'complete' : 'incomplete'}.',
        );
      } else if (draft.complete) {
        stdout.writeln(
          'Coverage marked complete by explicit owner assertion. Review this '
          'file whenever targets or entrypoints change.',
        );
      } else {
        stdout.writeln(
          'Coverage remains incomplete, so scan will cap candidates at '
          'REVIEW. Review the generated targets before setting complete: '
          'true.',
        );
      }
      stdout.writeln('Next: ${projectCommandFor(workspace, 'scan')}');
    }
    return 0;
  }

  void _writeInteractiveCompletion(ToolWorkspace workspace, _InitDraft draft) {
    final ui = _InitWizardPresentation(_prompt);
    ui.section('Configuration created', tone: _WizardTone.success);
    ui.field('Config', workspace.configFile.path, tone: _WizardTone.success);
    ui.field('Analysis mode', draft.projectType, tone: _WizardTone.accent);
    if (draft.projectType == 'package') {
      ui.warning(
        'Reusable-package consumers are open-world. Findings stay capped at '
        'REVIEW regardless of target completeness.',
      );
    } else if (draft.projectType == 'package-internal') {
      ui.warning(
        'Package-internal mode excludes external consumers. Scan and apply '
        'will display a persistent warning. Target coverage is '
        '${draft.complete ? 'complete' : 'incomplete'}.',
      );
    } else if (draft.complete) {
      ui.success(
        'Coverage marked complete by explicit owner assertion. Review this '
        'file whenever targets or entrypoints change.',
      );
    } else {
      ui.warning(
        'Coverage remains incomplete, so scan will cap candidates at REVIEW. '
        'Review the generated targets before setting complete: true.',
      );
    }
    ui.field(
      'Next',
      projectCommandFor(workspace, 'scan'),
      tone: _WizardTone.success,
    );
  }

  Future<void> _writeConfigAtomically(
    ToolWorkspace workspace,
    String contents, {
    required bool preserveBackup,
  }) async {
    final destination = workspace.configFile;
    final temporary = File('${destination.path}.tmp');
    final backup = File('${destination.path}.bak');
    final validationDirectory = await Directory.systemTemp.createTemp(
      'flutter_pruner_init_',
    );
    try {
      final validationFile = File(
        p.join(validationDirectory.path, 'config.yaml'),
      );
      await validationFile.writeAsString(contents, flush: true);
      await ProjectConfig.load(
        validationFile,
        projectRoot: workspace.projectRoot,
      );
    } finally {
      if (validationDirectory.existsSync()) {
        await validationDirectory.delete(recursive: true);
      }
    }

    await workspace.directory.create(recursive: true);
    if (temporary.existsSync()) await temporary.delete();
    await temporary.writeAsString(contents, flush: true);

    if (destination.existsSync() && preserveBackup) {
      if (backup.existsSync()) await backup.delete();
      await destination.copy(backup.path);
    }

    try {
      await temporary.rename(destination.path);
    } on FileSystemException {
      if (!destination.existsSync() || !backup.existsSync()) rethrow;
      await destination.delete();
      try {
        await temporary.rename(destination.path);
      } catch (_) {
        if (!destination.existsSync() && backup.existsSync()) {
          await backup.copy(destination.path);
        }
        rethrow;
      }
    }
  }

  Future<String?> _readPackageName(File pubspecFile) async {
    if (!pubspecFile.existsSync()) {
      stderr.writeln('Error: no pubspec.yaml found at ${pubspecFile.path}.');
      return null;
    }
    final Object? parsed;
    try {
      parsed = loadYaml(await pubspecFile.readAsString());
    } on YamlException catch (error) {
      stderr.writeln('Error: could not parse ${pubspecFile.path}: $error');
      return null;
    }
    final packageName = parsed is Map ? parsed['name'] : null;
    if (packageName is! String || packageName.isEmpty) {
      stderr.writeln('Error: pubspec.yaml is missing a package name.');
      return null;
    }
    return packageName;
  }

  String? _detectType(Directory projectRoot, String packageName) {
    if (File(
      p.join(projectRoot.path, 'lib', '$packageName.dart'),
    ).existsSync()) {
      return 'package';
    }
    if (File(p.join(projectRoot.path, 'lib', 'main.dart')).existsSync()) {
      return 'application';
    }
    return null;
  }

  bool _isHybridProject(Directory projectRoot, String packageName) =>
      File(p.join(projectRoot.path, 'lib', 'main.dart')).existsSync() &&
      File(p.join(projectRoot.path, 'lib', '$packageName.dart')).existsSync();

  bool _hasSecondaryTopLevelLibrary(Directory projectRoot) {
    final libraryDirectory = Directory(p.join(projectRoot.path, 'lib'));
    if (!libraryDirectory.existsSync()) return false;
    return libraryDirectory.listSync().whereType<File>().any((file) {
      final name = p.basename(file.path);
      return name != 'main.dart' &&
          name.endsWith('.dart') &&
          !name.endsWith('.g.dart') &&
          !name.endsWith('.freezed.dart');
    });
  }

  String _defaultEntrypoint(String projectType, String packageName) =>
      projectType == 'application' ? 'lib/main.dart' : 'lib/$packageName.dart';

  bool _isFlutterPackage(File pubspecFile) {
    try {
      final parsed = loadYaml(pubspecFile.readAsStringSync());
      final dependencies = parsed is Map ? parsed['dependencies'] : null;
      return dependencies is Map && dependencies.containsKey('flutter');
    } on YamlException {
      return false;
    }
  }

  List<String> _detectedPlatforms(
    Directory projectRoot, {
    required bool isFlutterPackage,
    required String projectType,
  }) {
    final detected = _supportedPlatforms
        .where(
          (platform) =>
              Directory(p.join(projectRoot.path, platform)).existsSync(),
        )
        .toList();
    if (detected.isNotEmpty) return detected;
    if (projectType == 'package' && isFlutterPackage) return ['android', 'ios'];
    if (projectType == 'package') return ['linux'];
    return ['android'];
  }

  List<String> _unique(Iterable<String> values) {
    final unique = <String>{};
    return [
      for (final value in values)
        if (unique.add(value)) value,
    ];
  }

  List<List<String>> _verificationCommands({
    required Directory projectRoot,
    required bool isFlutterPackage,
  }) {
    final usesFvm = _hasFvmMarker(projectRoot);
    final tool = isFlutterPackage ? 'flutter' : 'dart';
    final prefix = usesFvm ? ['fvm', tool] : [tool];
    final commands = <List<String>>[
      [
        ...prefix,
        'analyze',
        '--fatal-infos',
        '--fatal-warnings',
        if (isFlutterPackage) '--no-pub',
      ],
    ];
    if (Directory(p.join(projectRoot.path, 'test')).existsSync()) {
      commands.add([...prefix, 'test']);
    }
    return commands;
  }

  bool _hasFvmMarker(Directory projectRoot) {
    var current = projectRoot;
    while (true) {
      if (Directory(p.join(current.path, '.fvm')).existsSync() ||
          File(p.join(current.path, '.fvmrc')).existsSync()) {
        return true;
      }
      final parent = current.parent;
      if (parent.path == current.path) return false;
      current = parent;
    }
  }

  _InitDraft _buildNonInteractiveDraft({
    required ArgResults args,
    required ToolWorkspace workspace,
    required File pubspecFile,
    required String packageName,
    required String projectType,
    required bool isHybridProject,
  }) {
    final isApplication = projectType == 'application';
    final sourceKind = isApplication
        ? ProjectSourceKind.applicationEntrypoint
        : ProjectSourceKind.publicLibrary;
    final explicitEntrypoints = args.multiOption('entrypoint');
    final explicitPlatforms = args.multiOption('platform');
    final complete = args.flag('complete');
    final publicEntrypoints = <String>[];
    late final List<BuildTarget> targets;

    if (isApplication &&
        explicitEntrypoints.isEmpty &&
        explicitPlatforms.isEmpty) {
      final discovery = InitTargetDiscovery(
        workspace.projectRoot,
      ).discoverApplication();
      if (discovery.targets.isEmpty) {
        throw const FormatException(
          'No valid application targets were detected. Pass --entrypoint and '
          '--platform explicitly.',
        );
      }
      if (complete && discovery.issues.isNotEmpty) {
        throw FormatException(
          'Cannot assert complete coverage while discovery has unresolved '
          'issues: ${discovery.issues.first.message}',
        );
      }
      targets = discovery.targets;
    } else {
      final rawEntrypoints = explicitEntrypoints.isEmpty
          ? [_defaultEntrypoint(projectType, packageName)]
          : explicitEntrypoints;
      final entrypoints = _unique(
        rawEntrypoints.map(
          (entrypoint) => ProjectSourcePath.validate(
            workspace.projectRoot,
            entrypoint,
            field: '--entrypoint',
            kind: sourceKind,
          ),
        ),
      );
      final platforms = explicitPlatforms.isEmpty
          ? _detectedPlatforms(
              workspace.projectRoot,
              isFlutterPackage: _isFlutterPackage(pubspecFile),
              projectType: projectType,
            )
          : _unique(explicitPlatforms);
      targets = _targetsFromSelections(entrypoints, platforms);
      if (!isApplication) publicEntrypoints.addAll(entrypoints);
    }

    if (complete &&
        isApplication &&
        _hasSecondaryTopLevelLibrary(workspace.projectRoot) &&
        !args.wasParsed('type')) {
      throw const FormatException(
        'Additional top-level Dart libraries exist under lib/. Pass --type '
        'application only after confirming they are not public package roots.',
      );
    }
    if (complete && isApplication) {
      final unsupportedIssue = InitTargetDiscovery(workspace.projectRoot)
          .discoverApplication()
          .issues
          .where((issue) => !issue.ownerResolvable)
          .firstOrNull;
      if (unsupportedIssue != null) {
        throw FormatException(
          'Cannot assert complete coverage: ${unsupportedIssue.message}',
        );
      }
    }
    return _InitDraft(
      projectType: projectType,
      publicEntrypoints: List.unmodifiable(publicEntrypoints),
      targets: List.unmodifiable(targets),
      complete: complete,
      verification: _verificationCommands(
        projectRoot: workspace.projectRoot,
        isFlutterPackage: _isFlutterPackage(pubspecFile),
      ),
    );
  }

  _InitDraft _buildInteractiveDraft({
    required ToolWorkspace workspace,
    required File pubspecFile,
    required String packageName,
    required String? detectedType,
    required bool isHybridProject,
  }) {
    final questions = InitQuestions(_prompt, styled: true);
    final ui = _InitWizardPresentation(_prompt)
      ..banner(workspace.projectRoot.path);
    final defaultProjectType = detectedType ?? 'application';
    if (detectedType != null) {
      ui.info(
        isHybridProject
            ? 'Detected a hybrid project; package is the safe default.'
            : 'Detected $detectedType.',
      );
    } else {
      ui.warning('No conventional entrypoint was detected at:');
      ui.bullet('lib/main.dart');
      ui.bullet('lib/$packageName.dart');
      ui.detail('Choose the boundary and path explicitly.');
    }
    final projectType = _askProjectType(questions, defaultProjectType, ui);
    ui.field('Selected mode', projectType, tone: _WizardTone.accent);

    final publicEntrypoints = <String>[];
    late final List<BuildTarget> targets;
    var complete = false;
    if (projectType == 'application') {
      ui.section('Target coverage');
      final discovery = InitTargetDiscovery(
        workspace.projectRoot,
      ).discoverApplication();
      if (discovery.targets.isNotEmpty) {
        ui.info('Detected targets');
        for (final target in discovery.targets) {
          ui.bullet(_targetSummary(target));
        }
      }
      final useDetected =
          discovery.targets.isNotEmpty &&
          questions.yesNo('Use these detected targets?', defaultValue: true);
      targets = useDetected
          ? List<BuildTarget>.from(discovery.targets)
          : _askTargets(questions, workspace.projectRoot);
      if (useDetected &&
          questions.yesNo('Add another target?', defaultValue: false)) {
        targets.addAll(_askTargets(questions, workspace.projectRoot));
      }

      var issuesResolved = true;
      for (final issue in discovery.issues) {
        ui.warning(issue.message);
        if (!issue.ownerResolvable) {
          issuesResolved = false;
          continue;
        }
        if (!questions.yesNo(issue.resolution, defaultValue: false)) {
          issuesResolved = false;
        }
      }
      if (isHybridProject) {
        ui.warning(
          'Coverage will remain incomplete because the public library has '
          'open-world consumers.',
        );
      } else if (issuesResolved) {
        complete = questions.yesNo(
          'Have you declared every shipped platform, flavor, entrypoint, and '
          'dart-define combination?',
          defaultValue: false,
        );
      } else {
        ui.warning(
          'Coverage will remain incomplete until every warning is resolved.',
        );
      }
    } else {
      ui.section('Package boundary');
      final defaultPublicEntrypoint = _defaultEntrypoint(
        projectType,
        packageName,
      );
      String? suggested;
      try {
        suggested = ProjectSourcePath.validate(
          workspace.projectRoot,
          defaultPublicEntrypoint,
          field: 'public entrypoint',
          kind: ProjectSourceKind.publicLibrary,
        );
      } on ProjectSourcePathException catch (error) {
        ui.warning('Default public library cannot be used: ${error.message}');
        ui.detail('Enter another public library path.');
      }
      if (suggested != null &&
          questions.yesNo(
            'Use public library "$suggested"?',
            defaultValue: true,
          )) {
        publicEntrypoints.add(suggested);
      } else {
        publicEntrypoints.addAll(
          _askSourcePaths(
            questions,
            workspace.projectRoot,
            kind: ProjectSourceKind.publicLibrary,
            label: 'Public library path',
            defaultValue: suggested,
          ),
        );
      }
      ui.section('Target coverage');
      final platforms = _detectedPlatforms(
        workspace.projectRoot,
        isFlutterPackage: _isFlutterPackage(pubspecFile),
        projectType: projectType,
      );
      ui.field('Detected platforms', platforms.join(', '));
      final accepted = questions.yesNo(
        'Use these detected platforms?',
        defaultValue: true,
      );
      final selectedPlatforms = accepted
          ? platforms
          : _askPlatforms(questions, platforms.first);
      targets = _targetsFromSelections(publicEntrypoints, selectedPlatforms);
      complete = questions.yesNo(
        'Have you declared every supported platform, flavor, entrypoint, and '
        'dart-define combination?',
        defaultValue: false,
      );
      if (projectType == 'package') {
        ui.info(
          'Package findings remain REVIEW-only because consumers are '
          'open-world.',
        );
      } else {
        ui.warning('Package-internal can produce actionable SAFE findings.');
        ui.warning(
          'Eligible HIGH findings require explicit external-consumer risk '
          'acknowledgement.',
        );
      }
    }

    final verification = _verificationCommands(
      projectRoot: workspace.projectRoot,
      isFlutterPackage: _isFlutterPackage(pubspecFile),
    );
    ui.section('Verification');
    ui.info('Verifier commands');
    for (final command in verification) {
      ui.bullet(command.join(' '));
    }
    if (!questions.yesNo('Use these verifier commands?', defaultValue: true)) {
      ui.warning(
        'Custom verifier input is not supported by the wizard yet. Create '
        'the config non-interactively, then edit verification.steps.',
      );
      throw const InitCancelledException();
    }
    ui.section('Review configuration');
    ui.field('Analysis mode', projectType, tone: _WizardTone.accent);
    ui.field('Build targets', '${targets.length}');
    ui.field(
      'Target coverage',
      complete ? 'complete' : 'incomplete',
      tone: complete ? _WizardTone.success : _WizardTone.warning,
    );
    if (projectType == 'package') {
      ui.info('Action policy: audit only; external consumers are open-world.');
    } else if (projectType == 'package-internal') {
      ui.warning(
        'Analysis boundary: local package; external consumers are not '
        'scanned.',
      );
      ui.warning(
        'Action policy: SAFE can be applied; eligible HIGH requires '
        'confirmation.',
      );
    }
    if (!questions.yesNo('Write the configuration?', defaultValue: true)) {
      throw const InitCancelledException();
    }
    return _InitDraft(
      projectType: projectType,
      publicEntrypoints: List.unmodifiable(publicEntrypoints),
      targets: List.unmodifiable(targets),
      complete: complete,
      verification: List.unmodifiable(verification),
    );
  }

  String _askProjectType(
    InitQuestions questions,
    String defaultValue,
    _InitWizardPresentation ui,
  ) {
    final defaultChoice = switch (defaultValue) {
      'application' => '1',
      'package' => '2',
      'package-internal' => '3',
      _ => throw StateError('Unsupported project type: $defaultValue'),
    };
    ui.section('Analysis mode');
    ui.option(
      1,
      'application',
      isDefault: defaultValue == 'application',
      description:
          'Use when this project owns the complete application boundary.',
    );
    ui.option(
      2,
      'package',
      isDefault: defaultValue == 'package',
      description:
          'Reusable/public package; external consumers keep findings at '
          'REVIEW.',
    );
    ui.option(
      3,
      'package-internal',
      isDefault: defaultValue == 'package-internal',
      description:
          'Local package boundary; may produce actionable SAFE findings.',
      caution:
          'External-consumer candidates may be HIGH and need confirmation.',
    );
    return questions.text(
      'Select mode',
      defaultValue: defaultChoice,
      validate: (value) {
        switch (value.trim().toLowerCase()) {
          case '1':
          case 'application':
            return 'application';
          case '2':
          case 'package':
            return 'package';
          case '3':
          case 'package-internal':
            return 'package-internal';
          default:
            throw const FormatException(
              'Enter 1, 2, or 3 (application, package, or package-internal).',
            );
        }
      },
    );
  }

  List<BuildTarget> _askTargets(
    InitQuestions questions,
    Directory projectRoot,
  ) {
    final targets = <BuildTarget>[];
    do {
      final platform = questions.text(
        'Platform',
        defaultValue: 'android',
        validate: _validatePlatform,
      );
      final flavor = questions.optionalText('Flavor');
      final entrypoint = questions.text(
        'Entrypoint path',
        defaultValue: flavor == null
            ? 'lib/main.dart'
            : 'lib/main_$flavor.dart',
        validate: (value) => _validatePromptSourcePath(
          projectRoot,
          value,
          field: 'entrypoint',
          kind: ProjectSourceKind.applicationEntrypoint,
        ),
      );
      final preferredName = '$platform-${flavor ?? 'default'}';
      final name = questions.text(
        'Target name',
        defaultValue: preferredName,
        validate: (value) => _validateTargetName(value, targets),
      );
      final defines = <String, String>{};
      while (questions.yesNo('Add a dart-define?', defaultValue: false)) {
        final key = questions.text(
          'Dart define key',
          validate: (value) {
            if (value.isEmpty || defines.containsKey(value)) {
              throw const FormatException('Key must be non-empty and unique.');
            }
            return value;
          },
        );
        defines[key] = questions.text(
          'Dart define value',
          defaultValue: 'true',
          validate: (value) => value,
        );
      }
      targets.add(
        BuildTarget(
          name: name,
          platform: platform,
          flavor: flavor,
          entrypoint: entrypoint,
          dartDefines: Map.unmodifiable(defines),
        ),
      );
    } while (questions.yesNo('Add another target?', defaultValue: false));
    return targets;
  }

  List<String> _askSourcePaths(
    InitQuestions questions,
    Directory projectRoot, {
    required ProjectSourceKind kind,
    required String label,
    required String? defaultValue,
  }) {
    final paths = <String>[];
    do {
      final path = questions.text(
        label,
        defaultValue: defaultValue,
        validate: (value) {
          final normalized = _validatePromptSourcePath(
            projectRoot,
            value,
            field: label,
            kind: kind,
          );
          if (paths.contains(normalized)) {
            throw const FormatException('Path has already been added.');
          }
          return normalized;
        },
      );
      paths.add(path);
    } while (questions.yesNo(
      'Add another public library?',
      defaultValue: false,
    ));
    return paths;
  }

  List<String> _askPlatforms(InitQuestions questions, String defaultValue) {
    final raw = questions.text(
      'Platforms (comma-separated)',
      defaultValue: defaultValue,
      validate: (value) {
        final values = value.split(',').map((part) => part.trim()).toList();
        if (values.isEmpty || values.any((part) => part.isEmpty)) {
          throw const FormatException('At least one platform is required.');
        }
        for (final platform in values) {
          _validatePlatform(platform);
        }
        return values.join(',');
      },
    );
    return _unique(raw.split(',').map((part) => part.trim()));
  }

  String _validatePlatform(String value) {
    if (!_supportedPlatforms.contains(value)) {
      throw FormatException('Use one of: ${_supportedPlatforms.join(', ')}.');
    }
    return value;
  }

  String _validatePromptSourcePath(
    Directory projectRoot,
    String value, {
    required String field,
    required ProjectSourceKind kind,
  }) {
    try {
      return ProjectSourcePath.validate(
        projectRoot,
        value,
        field: field,
        kind: kind,
        allowAbsoluteInput: true,
      );
    } on ProjectSourcePathException catch (error) {
      throw FormatException(error.message);
    }
  }

  String _validateTargetName(String value, List<BuildTarget> targets) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(value)) {
      throw const FormatException(
        'Use letters, digits, dot, underscore, or hyphen.',
      );
    }
    if (targets.any((target) => target.name == value)) {
      throw const FormatException('Target name must be unique.');
    }
    return value;
  }

  List<BuildTarget> _targetsFromSelections(
    List<String> entrypoints,
    List<String> platforms,
  ) {
    final targets = <BuildTarget>[];
    for (final platform in platforms) {
      for (final entrypoint in entrypoints) {
        final basename = p.posix.basenameWithoutExtension(entrypoint);
        final flavor = basename.startsWith('main_')
            ? basename.substring(5)
            : null;
        final preferred = '$platform-${flavor ?? 'default'}';
        var name = preferred;
        var suffix = 2;
        while (targets.any((target) => target.name == name)) {
          name = '$preferred-${suffix++}';
        }
        targets.add(
          BuildTarget(
            name: name,
            platform: platform,
            flavor: flavor,
            entrypoint: entrypoint,
          ),
        );
      }
    }
    return targets;
  }

  String _targetSummary(BuildTarget target) {
    final details = <String>[
      target.name,
      target.platform,
      if (target.flavor != null) 'flavor=${target.flavor}',
      target.entrypoint,
    ];
    return details.join(' | ');
  }

  String _renderConfig({
    required String projectType,
    required List<String> publicEntrypoints,
    required List<BuildTarget> targets,
    required bool complete,
    required List<List<String>> verification,
  }) {
    final buffer = StringBuffer('''
# Flutter Pruner project configuration (schema version 1).
# Review every target before asserting that the matrix is complete.
version: 1

# The mode controls root strategy and apply authorization.
analysis:
  mode: $projectType
''');
    if (projectType != 'application') {
      buffer.writeln('  # Every public library that consumers may import.');
      buffer.writeln('  public_entrypoints:');
      for (final entrypoint in publicEntrypoints) {
        buffer.writeln('    - ${_yamlScalar(entrypoint)}');
      }
    }
    buffer.write('''

# Set complete only after declaring every supported build target.
target_matrix:
  complete: $complete
  targets:
''');
    for (final target in targets) {
      buffer.writeln('    - name: ${_yamlScalar(target.name)}');
      buffer.writeln('      platform: ${_yamlScalar(target.platform)}');
      if (target.flavor != null) {
        buffer.writeln('      flavor: ${_yamlScalar(target.flavor!)}');
      }
      buffer.writeln('      entrypoint: ${_yamlScalar(target.entrypoint)}');
      if (target.dartDefines.isNotEmpty) {
        buffer.writeln('      dart_defines:');
        for (final entry in target.dartDefines.entries) {
          buffer.writeln(
            '        ${_yamlScalar(entry.key)}: ${_yamlScalar(entry.value)}',
          );
        }
      }
    }
    buffer.write('''

# Commands run before and after each mutation transaction.
verification:
  steps:
''');
    for (final command in verification) {
      final id = command[0] == 'fvm' ? command[1] : command[0];
      final operation = command.last == 'test' ? 'test' : 'analyze';
      buffer.writeln('    - id: $id-$operation');
      buffer.writeln('      argv: [${command.map(_yamlScalar).join(', ')}]');
    }
    return buffer.toString();
  }

  String _yamlScalar(String value) {
    const yamlKeywords = {'null', 'true', 'false', 'yes', 'no', 'on', 'off'};
    final lower = value.toLowerCase();
    if (RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(value) &&
        !yamlKeywords.contains(lower) &&
        num.tryParse(value) == null) {
      return value;
    }
    return jsonEncode(value);
  }

  static const _gitignore = '''
# Keep the reviewed configuration, ignore generated Flutter Pruner state.
*
!.gitignore
!config.yaml
''';
}

enum _WizardTone { normal, accent, success, warning }

class _InitWizardPresentation {
  const _InitWizardPresentation(this._prompt);

  final InitPrompt _prompt;

  void banner(String projectPath) {
    _prompt.writeln(_style('◆ FLUTTER PRUNER · INIT', '$_ansiBold$_ansiCyan'));
    _prompt.writeln(
      '  ${_style('Conservative setup for a safe analysis boundary.', _ansiDim)}',
    );
    _prompt.writeln();
    field('Project', projectPath, tone: _WizardTone.accent);
  }

  void section(String label, {_WizardTone tone = _WizardTone.normal}) {
    final color = switch (tone) {
      _WizardTone.success => _ansiGreen,
      _WizardTone.warning => _ansiYellow,
      _ => _ansiCyan,
    };
    final marker = tone == _WizardTone.success ? '✓' : '◆';
    _prompt.writeln();
    _prompt.writeln(
      '${_style(marker, '$color$_ansiBold')} '
      '${_style(label.toUpperCase(), '$_ansiBold$color')}',
    );
  }

  void field(
    String label,
    String value, {
    _WizardTone tone = _WizardTone.normal,
  }) {
    final valueStyle = switch (tone) {
      _WizardTone.accent => '$_ansiBold$_ansiMagenta',
      _WizardTone.success => '$_ansiBold$_ansiGreen',
      _WizardTone.warning => '$_ansiBold$_ansiYellow',
      _WizardTone.normal => '',
    };
    final marker = _style('◇', _ansiCyan);
    final key = _style('$label:'.padRight(19), _ansiDim);
    _prompt.writeln('  $marker $key ${_style(value, valueStyle)}');
  }

  void option(
    int index,
    String label, {
    required bool isDefault,
    required String description,
    String? caution,
  }) {
    final number = _style('$index)', '$_ansiBold$_ansiCyan');
    final name = _style(label, '$_ansiBold$_ansiMagenta');
    final badge = isDefault
        ? '  ${_style('DEFAULT', '$_ansiBold$_ansiGreen')}'
        : '';
    _prompt.writeln('  $number $name$badge');
    detail(description);
    if (caution != null) warning(caution, indent: 5);
  }

  void info(String value) {
    final marker = _style('◇', _ansiCyan);
    _prompt.writeln('  $marker $value');
  }

  void detail(String value) {
    _prompt.writeln('     $value');
  }

  void bullet(String value) {
    _prompt.writeln('    ${_style('-', _ansiCyan)} $value');
  }

  void warning(String value, {int indent = 2}) {
    final marker = _style('!', '$_ansiBold$_ansiYellow');
    _prompt.writeln(
      '${''.padLeft(indent)}$marker ${_style(value, _ansiYellow)}',
    );
  }

  void success(String value) {
    final marker = _style('✓', '$_ansiBold$_ansiGreen');
    _prompt.writeln('  $marker ${_style(value, _ansiGreen)}');
  }

  String _style(String value, String style) {
    if (style.isEmpty || _prompt is! AnsiInitPrompt) {
      return value;
    }
    final ansiPrompt = _prompt as AnsiInitPrompt;
    if (!ansiPrompt.supportsAnsiEscapes) return value;
    return '$style$value$_ansiReset';
  }
}

const _ansiReset = '\x1B[0m';
const _ansiBold = '\x1B[1m';
const _ansiDim = '\x1B[2m';
const _ansiGreen = '\x1B[32m';
const _ansiYellow = '\x1B[33m';
const _ansiMagenta = '\x1B[35m';
const _ansiCyan = '\x1B[36m';

class _InitDraft {
  const _InitDraft({
    required this.projectType,
    required this.publicEntrypoints,
    required this.targets,
    required this.complete,
    required this.verification,
  });

  final String projectType;
  final List<String> publicEntrypoints;
  final List<BuildTarget> targets;
  final bool complete;
  final List<List<String>> verification;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
