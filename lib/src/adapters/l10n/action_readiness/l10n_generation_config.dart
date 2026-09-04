import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../../../core/project/project_context.dart';
import 'immutable_bytes.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_toolchain.dart';

const _stage = 'generation-config-load';

/// Frozen schema-v1 variants for the exact supported Flutter toolchains.
enum L10nGenerationSchemaVersion {
  /// Flutter 3.38.7 gen-l10n schema-v1.
  flutter3387,

  /// Flutter 3.41.5 gen-l10n schema-v1.
  flutter3415,

  /// Flutter 3.44.1 gen-l10n schema-v1.
  flutter3441,

  /// Flutter 3.44.9 gen-l10n schema-v1.
  flutter3449,
}

/// Result of loading strict, byte-bound gen-l10n configuration.
sealed class L10nGenerationConfigLoadResult {
  const L10nGenerationConfigLoadResult();
}

/// A strict generation configuration that is ready for later evidence stages.
final class L10nGenerationConfigReady extends L10nGenerationConfigLoadResult {
  /// Creates a ready result for [config].
  const L10nGenerationConfigReady(this.config);

  /// The immutable effective configuration.
  final L10nGenerationConfig config;
}

/// Stable reasons why strict generation configuration could not be loaded.
final class L10nGenerationConfigRejected
    extends L10nGenerationConfigLoadResult {
  /// Creates a rejection with a defensive immutable failure list.
  L10nGenerationConfigRejected(List<L10nEvidenceFailure> failures)
    : failures = List<L10nEvidenceFailure>.unmodifiable(failures);

  /// Deterministically ordered structured failures.
  final List<L10nEvidenceFailure> failures;
}

/// Loads strict generation configuration for one frozen Flutter toolchain.
abstract interface class L10nGenerationConfigLoader {
  /// Loads the raw project authorities and their schema-v1 effective values.
  Future<L10nGenerationConfigLoadResult> load({
    required ProjectContext project,
    required FlutterMachineIdentity toolchain,
  });
}

/// Immutable strict configuration used by V3.1 action-readiness stages.
final class L10nGenerationConfig {
  L10nGenerationConfig._({
    required this.schemaVersion,
    required this.pubspecBytes,
    required this.yamlBytes,
    required this.arbDirectory,
    required this.templateArbPath,
    required this.outputDirectory,
    required this.baseOutputPath,
    required this.untranslatedMessagesPath,
    required this.headerFilePath,
    required this.header,
    required this.outputClass,
    required List<String> preferredSupportedLocales,
    required this.useDeferredLoading,
    required this.requiredResourceAttributes,
    required this.nullableGetter,
    required this.format,
    required this.useEscaping,
    required this.suppressWarnings,
    required this.relaxSyntax,
    required this.useNamedParameters,
    required this.useCrLfOutputs,
    required this.configurationIdentity,
  }) : preferredSupportedLocales = List<String>.unmodifiable(
         preferredSupportedLocales,
       );

  /// Exact immutable schema table selected by the toolchain version.
  final L10nGenerationSchemaVersion schemaVersion;

  /// Exact retained bytes of the project pubspec.
  final ImmutableBytes pubspecBytes;

  /// Exact retained l10n.yaml bytes, or null when the file is absent.
  final ImmutableBytes? yamlBytes;

  /// Safe project-relative POSIX ARB directory.
  final String arbDirectory;

  /// Safe project-relative POSIX template ARB path.
  final String templateArbPath;

  /// Safe project-relative POSIX generated-output directory.
  final String outputDirectory;

  /// Safe project-relative POSIX base generated Dart path.
  final String baseOutputPath;

  /// Safe project-relative untranslated sidecar path, when configured.
  final String? untranslatedMessagesPath;

  /// Safe project-relative header input path, when configured.
  final String? headerFilePath;

  /// Inline header contents, when configured.
  final String? header;

  /// Generated localization class name.
  final String outputClass;

  /// Preferred locales in exact configured order.
  final List<String> preferredSupportedLocales;

  /// Whether locale libraries are generated as deferred imports.
  final bool useDeferredLoading;

  /// Whether every resource requires metadata attributes.
  final bool requiredResourceAttributes;

  /// Whether the generated localization getter is nullable.
  final bool nullableGetter;

  /// Whether Flutter formats generated Dart output.
  final bool format;

  /// Whether ICU escaping is enabled.
  final bool useEscaping;

  /// Whether generator warnings are suppressed.
  final bool suppressWarnings;

  /// Whether relaxed ICU syntax is enabled.
  final bool relaxSyntax;

  /// Whether generated message methods use named parameters.
  final bool useNamedParameters;

  /// Whether generated Dart outputs use CRLF line endings.
  final bool useCrLfOutputs;

  /// Length/NUL-framed SHA-256 identity of all controlling facts.
  final String configurationIdentity;
}

/// Sole production implementation of [L10nGenerationConfigLoader].
final class DefaultL10nGenerationConfigLoader
    implements L10nGenerationConfigLoader {
  /// Creates the stateless strict loader.
  const DefaultL10nGenerationConfigLoader();

  @override
  Future<L10nGenerationConfigLoadResult> load({
    required ProjectContext project,
    required FlutterMachineIdentity toolchain,
  }) async {
    final table = _tableFor(toolchain.frameworkVersion);
    if (table == null) {
      return _rejected(
        L10nEvidenceRejectionCode.unsupportedConfiguration,
        'unsupported-flutter-version',
      );
    }

    try {
      final canonicalRoot = _canonicalProjectRoot(project.root);
      final walker = _SafeProjectPathWalker(canonicalRoot);
      final pubspec = _captureAuthority(
        walker,
        'pubspec.yaml',
        required: true,
        notRegularDetail: 'pubspec-not-regular',
      )!;
      final pubspecRoot = _parseRequiredYamlMap(
        pubspec.bytes,
        invalidUtf8Detail: 'pubspec-yaml-invalid-utf8',
        malformedDetail: 'pubspec-yaml-malformed',
        rootDetail: 'pubspec-yaml-root-not-map',
        relativePath: 'pubspec.yaml',
      );
      if (!_hasExactFlutterGenerateTrue(pubspecRoot)) {
        throw _ConfigProblem(
          L10nEvidenceRejectionCode.unsupportedConfiguration,
          'flutter-generate-not-true',
          relativePath: 'pubspec.yaml',
        );
      }

      final yaml = _captureAuthority(
        walker,
        'l10n.yaml',
        required: false,
        notRegularDetail: 'l10n-config-not-regular',
      );
      if (yaml == null && !_hasFlutterDependency(pubspecRoot)) {
        throw const _ConfigProblem(
          L10nEvidenceRejectionCode.unsupportedConfiguration,
          'l10n-generation-not-applicable',
          relativePath: 'pubspec.yaml',
        );
      }
      final values = yaml == null
          ? const <String, YamlNode>{}
          : _parseConfigValues(yaml.bytes, table);

      if (table.headerAndHeaderFileMutuallyExclusive &&
          values.containsKey('header') &&
          values.containsKey('header-file')) {
        throw const _ConfigProblem(
          L10nEvidenceRejectionCode.unsupportedConfiguration,
          'header-options-conflict',
          relativePath: 'l10n.yaml',
        );
      }
      for (final entry in values.entries) {
        if (entry.value.value == null) {
          throw const _ConfigProblem(
            L10nEvidenceRejectionCode.unsupportedConfiguration,
            'l10n-option-null',
            relativePath: 'l10n.yaml',
          );
        }
      }

      final syntheticPackage =
          _optionalBool(values, 'synthetic-package') ??
          table.defaultSyntheticPackage;
      if (syntheticPackage && !table.syntheticPackageTrueSupported) {
        throw const _ConfigProblem(
          L10nEvidenceRejectionCode.unsupportedConfiguration,
          'synthetic-package-enabled',
          relativePath: 'l10n.yaml',
        );
      }

      final arbInput =
          _optionalString(values, 'arb-dir') ?? table.defaultArbDirectory;
      final arbDirectory = walker.resolve(
        arbInput,
        policy: _PathLeafPolicy.requiredDirectory,
      );
      final templateInput =
          _optionalString(values, 'template-arb-file') ??
          table.defaultTemplateArbFile;
      final templateArbPath = walker.resolve(
        _joinPosix(arbDirectory, templateInput),
        policy: _PathLeafPolicy.requiredFile,
      );

      final outputDirectoryInput =
          _optionalString(values, 'output-dir') ?? table.defaultOutputDirectory;
      final outputDirectory = outputDirectoryInput == null
          ? arbDirectory
          : walker.resolve(
              outputDirectoryInput,
              policy: _PathLeafPolicy.outputDirectory,
            );
      final outputFile =
          _optionalString(values, 'output-localization-file') ??
          table.defaultOutputLocalizationFile;
      _validateOutputLocalizationFile(outputFile);
      final baseOutputPath = walker.resolve(
        _joinPosix(outputDirectory, outputFile),
        policy: _PathLeafPolicy.outputFile,
      );

      final untranslatedInput =
          _optionalString(values, 'untranslated-messages-file') ??
          table.defaultUntranslatedMessagesFile;
      final untranslatedMessagesPath = untranslatedInput == null
          ? null
          : walker.resolve(
              untranslatedInput,
              policy: _PathLeafPolicy.outputFile,
            );
      final headerFileInput =
          _optionalString(values, 'header-file') ?? table.defaultHeaderFile;
      final headerFilePath = headerFileInput == null
          ? null
          : walker.resolve(
              _joinPosix(arbDirectory, headerFileInput),
              policy: _PathLeafPolicy.requiredFile,
            );

      final header =
          _optionalString(values, 'header', allowEmpty: true) ??
          table.defaultHeader;
      final outputClass =
          _optionalString(values, 'output-class') ?? table.defaultOutputClass;
      if (!_validOutputClass(outputClass)) {
        throw const _ConfigProblem(
          L10nEvidenceRejectionCode.unsupportedConfiguration,
          'l10n-option-invalid-value',
          relativePath: 'l10n.yaml',
        );
      }
      final preferredSupportedLocales =
          _optionalLocales(values, 'preferred-supported-locales') ??
          table.defaultPreferredSupportedLocales;
      if (preferredSupportedLocales.any(
        (locale) => !_validPreferredLocale(locale),
      )) {
        throw const _ConfigProblem(
          L10nEvidenceRejectionCode.unsupportedConfiguration,
          'l10n-option-invalid-value',
          relativePath: 'l10n.yaml',
        );
      }

      _rejectConfiguredPathRoleCollisions([
        const _ConfiguredPathRole.file('pubspec.yaml'),
        if (yaml != null) const _ConfiguredPathRole.file('l10n.yaml'),
        _ConfiguredPathRole.directory(arbDirectory),
        _ConfiguredPathRole.file(templateArbPath),
        _ConfiguredPathRole.directory(outputDirectory),
        _ConfiguredPathRole.file(baseOutputPath),
        if (untranslatedMessagesPath != null)
          _ConfiguredPathRole.file(untranslatedMessagesPath),
        if (headerFilePath != null) _ConfiguredPathRole.file(headerFilePath),
      ]);

      final useDeferredLoading =
          _optionalBool(values, 'use-deferred-loading') ??
          table.defaultUseDeferredLoading;
      final requiredResourceAttributes =
          _optionalBool(values, 'required-resource-attributes') ??
          table.defaultRequiredResourceAttributes;
      final nullableGetter =
          _optionalBool(values, 'nullable-getter') ??
          table.defaultNullableGetter;
      final format =
          _optionalBool(values, 'format') ??
          (yaml == null ? table.defaultCommandFormat : table.defaultYamlFormat);
      final useEscaping =
          _optionalBool(values, 'use-escaping') ?? table.defaultUseEscaping;
      final suppressWarnings =
          _optionalBool(values, 'suppress-warnings') ??
          table.defaultSuppressWarnings;
      final relaxSyntax =
          _optionalBool(values, 'relax-syntax') ?? table.defaultRelaxSyntax;
      final useNamedParameters =
          _optionalBool(values, 'use-named-parameters') ??
          table.defaultUseNamedParameters;
      final useCrLfOutputs = _containsCrLf(pubspec.bytes);

      _verifyAuthorityUnchanged(
        walker,
        'pubspec.yaml',
        pubspec,
        required: true,
        notRegularDetail: 'pubspec-not-regular',
      );
      _verifyAuthorityUnchanged(
        walker,
        'l10n.yaml',
        yaml,
        required: false,
        notRegularDetail: 'l10n-config-not-regular',
      );

      final identity = _configurationIdentity(
        table: table,
        toolchain: toolchain,
        yamlBytes: yaml?.bytes,
        arbDirectory: arbDirectory,
        templateArbPath: templateArbPath,
        outputDirectory: outputDirectory,
        baseOutputPath: baseOutputPath,
        untranslatedMessagesPath: untranslatedMessagesPath,
        headerFilePath: headerFilePath,
        header: header,
        outputClass: outputClass,
        preferredSupportedLocales: preferredSupportedLocales,
        useDeferredLoading: useDeferredLoading,
        requiredResourceAttributes: requiredResourceAttributes,
        nullableGetter: nullableGetter,
        format: format,
        useEscaping: useEscaping,
        suppressWarnings: suppressWarnings,
        relaxSyntax: relaxSyntax,
        useNamedParameters: useNamedParameters,
        useCrLfOutputs: useCrLfOutputs,
      );

      return L10nGenerationConfigReady(
        L10nGenerationConfig._(
          schemaVersion: table.schemaVersion,
          pubspecBytes: pubspec.bytes,
          yamlBytes: yaml?.bytes,
          arbDirectory: arbDirectory,
          templateArbPath: templateArbPath,
          outputDirectory: outputDirectory,
          baseOutputPath: baseOutputPath,
          untranslatedMessagesPath: untranslatedMessagesPath,
          headerFilePath: headerFilePath,
          header: header,
          outputClass: outputClass,
          preferredSupportedLocales: preferredSupportedLocales,
          useDeferredLoading: useDeferredLoading,
          requiredResourceAttributes: requiredResourceAttributes,
          nullableGetter: nullableGetter,
          format: format,
          useEscaping: useEscaping,
          suppressWarnings: suppressWarnings,
          relaxSyntax: relaxSyntax,
          useNamedParameters: useNamedParameters,
          useCrLfOutputs: useCrLfOutputs,
          configurationIdentity: identity,
        ),
      );
    } on _ConfigProblem catch (problem) {
      return _rejected(
        problem.code,
        problem.detailCode,
        relativePath: problem.relativePath,
      );
    } on FileSystemException {
      return _rejected(
        L10nEvidenceRejectionCode.invalidInputPath,
        'configuration-path-inspection-failed',
      );
    } on Object {
      return _rejected(
        L10nEvidenceRejectionCode.internalFailure,
        'configuration-load-unexpected-failure',
      );
    }
  }
}

enum _SchemaOptionRule {
  projectRelativePath,
  arbRelativePath,
  outputLocalizationFile,
  dartClassName,
  headerText,
  boolean,
  preferredLocales,
}

final class _SchemaV1Table {
  const _SchemaV1Table({
    required this.tableId,
    required this.schemaVersion,
    required this.optionRules,
    required this.headerAndHeaderFileMutuallyExclusive,
    required this.syntheticPackageTrueSupported,
    required this.defaultArbDirectory,
    required this.defaultOutputDirectory,
    required this.defaultTemplateArbFile,
    required this.defaultOutputLocalizationFile,
    required this.defaultUntranslatedMessagesFile,
    required this.defaultOutputClass,
    required this.defaultHeader,
    required this.defaultHeaderFile,
    required this.defaultUseDeferredLoading,
    required this.defaultPreferredSupportedLocales,
    required this.defaultRequiredResourceAttributes,
    required this.defaultNullableGetter,
    required this.defaultYamlFormat,
    required this.defaultCommandFormat,
    required this.defaultUseEscaping,
    required this.defaultSuppressWarnings,
    required this.defaultRelaxSyntax,
    required this.defaultUseNamedParameters,
    required this.defaultSyntheticPackage,
  });

  final String tableId;
  final L10nGenerationSchemaVersion schemaVersion;
  final Map<String, _SchemaOptionRule> optionRules;
  final bool headerAndHeaderFileMutuallyExclusive;
  final bool syntheticPackageTrueSupported;
  final String defaultArbDirectory;
  final String? defaultOutputDirectory;
  final String defaultTemplateArbFile;
  final String defaultOutputLocalizationFile;
  final String? defaultUntranslatedMessagesFile;
  final String defaultOutputClass;
  final String? defaultHeader;
  final String? defaultHeaderFile;
  final bool defaultUseDeferredLoading;
  final List<String> defaultPreferredSupportedLocales;
  final bool defaultRequiredResourceAttributes;
  final bool defaultNullableGetter;
  final bool defaultYamlFormat;
  final bool defaultCommandFormat;
  final bool defaultUseEscaping;
  final bool defaultSuppressWarnings;
  final bool defaultRelaxSyntax;
  final bool defaultUseNamedParameters;
  final bool defaultSyntheticPackage;
}

const _flutter3387Table = _SchemaV1Table(
  tableId: 'l10n-generation-schema-v1/flutter-3.38.7',
  schemaVersion: L10nGenerationSchemaVersion.flutter3387,
  optionRules: {
    'arb-dir': _SchemaOptionRule.projectRelativePath,
    'output-dir': _SchemaOptionRule.projectRelativePath,
    'template-arb-file': _SchemaOptionRule.arbRelativePath,
    'output-localization-file': _SchemaOptionRule.outputLocalizationFile,
    'untranslated-messages-file': _SchemaOptionRule.projectRelativePath,
    'output-class': _SchemaOptionRule.dartClassName,
    'header': _SchemaOptionRule.headerText,
    'header-file': _SchemaOptionRule.arbRelativePath,
    'use-deferred-loading': _SchemaOptionRule.boolean,
    'preferred-supported-locales': _SchemaOptionRule.preferredLocales,
    'required-resource-attributes': _SchemaOptionRule.boolean,
    'nullable-getter': _SchemaOptionRule.boolean,
    'format': _SchemaOptionRule.boolean,
    'use-escaping': _SchemaOptionRule.boolean,
    'suppress-warnings': _SchemaOptionRule.boolean,
    'relax-syntax': _SchemaOptionRule.boolean,
    'use-named-parameters': _SchemaOptionRule.boolean,
    'synthetic-package': _SchemaOptionRule.boolean,
  },
  headerAndHeaderFileMutuallyExclusive: true,
  syntheticPackageTrueSupported: false,
  defaultArbDirectory: 'lib/l10n',
  defaultOutputDirectory: null,
  defaultTemplateArbFile: 'app_en.arb',
  defaultOutputLocalizationFile: 'app_localizations.dart',
  defaultUntranslatedMessagesFile: null,
  defaultOutputClass: 'AppLocalizations',
  defaultHeader: null,
  defaultHeaderFile: null,
  defaultUseDeferredLoading: false,
  defaultPreferredSupportedLocales: [],
  defaultRequiredResourceAttributes: false,
  defaultNullableGetter: true,
  defaultYamlFormat: true,
  defaultCommandFormat: false,
  defaultUseEscaping: false,
  defaultSuppressWarnings: false,
  defaultRelaxSyntax: false,
  defaultUseNamedParameters: false,
  defaultSyntheticPackage: false,
);
const _flutter3415Table = _SchemaV1Table(
  tableId: 'l10n-generation-schema-v1/flutter-3.41.5',
  schemaVersion: L10nGenerationSchemaVersion.flutter3415,
  optionRules: {
    'arb-dir': _SchemaOptionRule.projectRelativePath,
    'output-dir': _SchemaOptionRule.projectRelativePath,
    'template-arb-file': _SchemaOptionRule.arbRelativePath,
    'output-localization-file': _SchemaOptionRule.outputLocalizationFile,
    'untranslated-messages-file': _SchemaOptionRule.projectRelativePath,
    'output-class': _SchemaOptionRule.dartClassName,
    'header': _SchemaOptionRule.headerText,
    'header-file': _SchemaOptionRule.arbRelativePath,
    'use-deferred-loading': _SchemaOptionRule.boolean,
    'preferred-supported-locales': _SchemaOptionRule.preferredLocales,
    'required-resource-attributes': _SchemaOptionRule.boolean,
    'nullable-getter': _SchemaOptionRule.boolean,
    'format': _SchemaOptionRule.boolean,
    'use-escaping': _SchemaOptionRule.boolean,
    'suppress-warnings': _SchemaOptionRule.boolean,
    'relax-syntax': _SchemaOptionRule.boolean,
    'use-named-parameters': _SchemaOptionRule.boolean,
    'synthetic-package': _SchemaOptionRule.boolean,
  },
  headerAndHeaderFileMutuallyExclusive: true,
  syntheticPackageTrueSupported: false,
  defaultArbDirectory: 'lib/l10n',
  defaultOutputDirectory: null,
  defaultTemplateArbFile: 'app_en.arb',
  defaultOutputLocalizationFile: 'app_localizations.dart',
  defaultUntranslatedMessagesFile: null,
  defaultOutputClass: 'AppLocalizations',
  defaultHeader: null,
  defaultHeaderFile: null,
  defaultUseDeferredLoading: false,
  defaultPreferredSupportedLocales: [],
  defaultRequiredResourceAttributes: false,
  defaultNullableGetter: true,
  defaultYamlFormat: true,
  defaultCommandFormat: false,
  defaultUseEscaping: false,
  defaultSuppressWarnings: false,
  defaultRelaxSyntax: false,
  defaultUseNamedParameters: false,
  defaultSyntheticPackage: false,
);
const _flutter3441Table = _SchemaV1Table(
  tableId: 'l10n-generation-schema-v1/flutter-3.44.1',
  schemaVersion: L10nGenerationSchemaVersion.flutter3441,
  optionRules: {
    'arb-dir': _SchemaOptionRule.projectRelativePath,
    'output-dir': _SchemaOptionRule.projectRelativePath,
    'template-arb-file': _SchemaOptionRule.arbRelativePath,
    'output-localization-file': _SchemaOptionRule.outputLocalizationFile,
    'untranslated-messages-file': _SchemaOptionRule.projectRelativePath,
    'output-class': _SchemaOptionRule.dartClassName,
    'header': _SchemaOptionRule.headerText,
    'header-file': _SchemaOptionRule.arbRelativePath,
    'use-deferred-loading': _SchemaOptionRule.boolean,
    'preferred-supported-locales': _SchemaOptionRule.preferredLocales,
    'required-resource-attributes': _SchemaOptionRule.boolean,
    'nullable-getter': _SchemaOptionRule.boolean,
    'format': _SchemaOptionRule.boolean,
    'use-escaping': _SchemaOptionRule.boolean,
    'suppress-warnings': _SchemaOptionRule.boolean,
    'relax-syntax': _SchemaOptionRule.boolean,
    'use-named-parameters': _SchemaOptionRule.boolean,
    'synthetic-package': _SchemaOptionRule.boolean,
  },
  headerAndHeaderFileMutuallyExclusive: true,
  syntheticPackageTrueSupported: false,
  defaultArbDirectory: 'lib/l10n',
  defaultOutputDirectory: null,
  defaultTemplateArbFile: 'app_en.arb',
  defaultOutputLocalizationFile: 'app_localizations.dart',
  defaultUntranslatedMessagesFile: null,
  defaultOutputClass: 'AppLocalizations',
  defaultHeader: null,
  defaultHeaderFile: null,
  defaultUseDeferredLoading: false,
  defaultPreferredSupportedLocales: [],
  defaultRequiredResourceAttributes: false,
  defaultNullableGetter: true,
  defaultYamlFormat: true,
  defaultCommandFormat: false,
  defaultUseEscaping: false,
  defaultSuppressWarnings: false,
  defaultRelaxSyntax: false,
  defaultUseNamedParameters: false,
  defaultSyntheticPackage: false,
);
const _flutter3449Table = _SchemaV1Table(
  tableId: 'l10n-generation-schema-v1/flutter-3.44.9',
  schemaVersion: L10nGenerationSchemaVersion.flutter3449,
  optionRules: {
    'arb-dir': _SchemaOptionRule.projectRelativePath,
    'output-dir': _SchemaOptionRule.projectRelativePath,
    'template-arb-file': _SchemaOptionRule.arbRelativePath,
    'output-localization-file': _SchemaOptionRule.outputLocalizationFile,
    'untranslated-messages-file': _SchemaOptionRule.projectRelativePath,
    'output-class': _SchemaOptionRule.dartClassName,
    'header': _SchemaOptionRule.headerText,
    'header-file': _SchemaOptionRule.arbRelativePath,
    'use-deferred-loading': _SchemaOptionRule.boolean,
    'preferred-supported-locales': _SchemaOptionRule.preferredLocales,
    'required-resource-attributes': _SchemaOptionRule.boolean,
    'nullable-getter': _SchemaOptionRule.boolean,
    'format': _SchemaOptionRule.boolean,
    'use-escaping': _SchemaOptionRule.boolean,
    'suppress-warnings': _SchemaOptionRule.boolean,
    'relax-syntax': _SchemaOptionRule.boolean,
    'use-named-parameters': _SchemaOptionRule.boolean,
    'synthetic-package': _SchemaOptionRule.boolean,
  },
  headerAndHeaderFileMutuallyExclusive: true,
  syntheticPackageTrueSupported: false,
  defaultArbDirectory: 'lib/l10n',
  defaultOutputDirectory: null,
  defaultTemplateArbFile: 'app_en.arb',
  defaultOutputLocalizationFile: 'app_localizations.dart',
  defaultUntranslatedMessagesFile: null,
  defaultOutputClass: 'AppLocalizations',
  defaultHeader: null,
  defaultHeaderFile: null,
  defaultUseDeferredLoading: false,
  defaultPreferredSupportedLocales: [],
  defaultRequiredResourceAttributes: false,
  defaultNullableGetter: true,
  defaultYamlFormat: true,
  defaultCommandFormat: false,
  defaultUseEscaping: false,
  defaultSuppressWarnings: false,
  defaultRelaxSyntax: false,
  defaultUseNamedParameters: false,
  defaultSyntheticPackage: false,
);

_SchemaV1Table? _tableFor(Version version) {
  return switch (version.toString()) {
    '3.38.7' => _flutter3387Table,
    '3.41.5' => _flutter3415Table,
    '3.44.1' => _flutter3441Table,
    '3.44.9' => _flutter3449Table,
    _ => null,
  };
}

Map<String, YamlNode> _parseConfigValues(
  ImmutableBytes bytes,
  _SchemaV1Table table,
) {
  final text = _decodeYamlBytes(
    bytes,
    invalidUtf8Detail: 'l10n-yaml-invalid-utf8',
    relativePath: 'l10n.yaml',
  );
  if (text.trim().isEmpty) return const {};

  final YamlNode root;
  try {
    root = loadYamlNode(text);
  } on YamlException {
    throw const _ConfigProblem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      'l10n-yaml-malformed',
      relativePath: 'l10n.yaml',
    );
  }
  if (root is! YamlMap) {
    throw const _ConfigProblem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      'l10n-yaml-root-not-map',
      relativePath: 'l10n.yaml',
    );
  }

  final values = <String, YamlNode>{};
  for (final entry in root.nodes.entries) {
    final key = (entry.key as YamlNode).value;
    if (key is! String) {
      throw const _ConfigProblem(
        L10nEvidenceRejectionCode.unsupportedConfiguration,
        'l10n-option-key-not-string',
        relativePath: 'l10n.yaml',
      );
    }
    final rule = table.optionRules[key];
    if (rule == null) {
      throw const _ConfigProblem(
        L10nEvidenceRejectionCode.unsupportedConfiguration,
        'l10n-option-unknown',
        relativePath: 'l10n.yaml',
      );
    }
    if (entry.value.value != null &&
        !_optionValueMatchesRule(entry.value, rule)) {
      _wrongType();
    }
    values[key] = entry.value;
  }
  return UnmodifiableMapView<String, YamlNode>(values);
}

bool _optionValueMatchesRule(YamlNode node, _SchemaOptionRule rule) {
  switch (rule) {
    case _SchemaOptionRule.projectRelativePath:
    case _SchemaOptionRule.arbRelativePath:
    case _SchemaOptionRule.outputLocalizationFile:
    case _SchemaOptionRule.dartClassName:
    case _SchemaOptionRule.headerText:
      return node is YamlScalar && node.value is String;
    case _SchemaOptionRule.boolean:
      return node is YamlScalar && node.value is bool;
    case _SchemaOptionRule.preferredLocales:
      if (node is YamlScalar) return node.value is String;
      if (node is! YamlList) return false;
      return node.nodes.every(
        (item) => item is YamlScalar && item.value is String,
      );
  }
}

YamlMap _parseRequiredYamlMap(
  ImmutableBytes bytes, {
  required String invalidUtf8Detail,
  required String malformedDetail,
  required String rootDetail,
  required String relativePath,
}) {
  final text = _decodeYamlBytes(
    bytes,
    invalidUtf8Detail: invalidUtf8Detail,
    relativePath: relativePath,
  );
  final YamlNode root;
  try {
    root = loadYamlNode(text);
  } on YamlException {
    throw _ConfigProblem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      malformedDetail,
      relativePath: relativePath,
    );
  }
  if (root is! YamlMap) {
    throw _ConfigProblem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      rootDetail,
      relativePath: relativePath,
    );
  }
  return root;
}

String _decodeYamlBytes(
  ImmutableBytes bytes, {
  required String invalidUtf8Detail,
  required String relativePath,
}) {
  try {
    return utf8.decode(bytes.copy(), allowMalformed: false);
  } on FormatException {
    throw _ConfigProblem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      invalidUtf8Detail,
      relativePath: relativePath,
    );
  }
}

bool _hasExactFlutterGenerateTrue(YamlMap pubspec) {
  final flutter = pubspec.nodes['flutter'];
  if (flutter is! YamlMap) return false;
  final generate = flutter.nodes['generate'];
  return generate is YamlScalar && generate.value == true;
}

bool _hasFlutterDependency(YamlMap pubspec) {
  final dependencies = pubspec.nodes['dependencies'];
  return dependencies is YamlMap && dependencies.nodes.containsKey('flutter');
}

String? _optionalString(
  Map<String, YamlNode> values,
  String key, {
  bool allowEmpty = true,
}) {
  final node = values[key];
  if (node == null) return null;
  final value = node.value;
  if (value is! String) _wrongType();
  if (!allowEmpty && value.isEmpty) {
    throw const _ConfigProblem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      'l10n-option-invalid-value',
      relativePath: 'l10n.yaml',
    );
  }
  return value;
}

bool? _optionalBool(Map<String, YamlNode> values, String key) {
  final node = values[key];
  if (node == null) return null;
  final value = node.value;
  if (value is! bool) _wrongType();
  return value;
}

List<String>? _optionalLocales(Map<String, YamlNode> values, String key) {
  final node = values[key];
  if (node == null) return null;
  if (node case YamlScalar(value: final String scalar)) {
    return List<String>.unmodifiable([scalar]);
  }
  if (node is! YamlList) _wrongType();
  final locales = <String>[];
  for (final item in node.nodes) {
    final value = item.value;
    if (value is! String) _wrongType();
    locales.add(value);
  }
  return List<String>.unmodifiable(locales);
}

Never _wrongType() => throw const _ConfigProblem(
  L10nEvidenceRejectionCode.unsupportedConfiguration,
  'l10n-option-wrong-type',
  relativePath: 'l10n.yaml',
);

bool _validOutputClass(String value) =>
    RegExp(r'^[A-Z][A-Za-z0-9_]*$').hasMatch(value);

bool _validPreferredLocale(String value) {
  final components = value.split('_');
  return components.length <= 3 &&
      components.every((component) => component.isNotEmpty);
}

String _canonicalProjectRoot(Directory root) {
  try {
    final type = FileSystemEntity.typeSync(root.path, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.link) {
      throw const _ConfigProblem(
        L10nEvidenceRejectionCode.invalidInputPath,
        'project-root-not-directory',
      );
    }
    return p.normalize(root.resolveSymbolicLinksSync());
  } on _ConfigProblem {
    rethrow;
  } on FileSystemException {
    throw const _ConfigProblem(
      L10nEvidenceRejectionCode.invalidInputPath,
      'project-root-not-directory',
    );
  }
}

enum _PathLeafPolicy {
  requiredDirectory,
  requiredFile,
  optionalAuthorityFile,
  outputDirectory,
  outputFile,
}

final class _PathResolution {
  const _PathResolution({required this.relativePath, required this.exists});

  final String relativePath;
  final bool exists;
}

final class _SafeProjectPathWalker {
  const _SafeProjectPathWalker(this.root);

  final String root;

  String resolve(String input, {required _PathLeafPolicy policy}) =>
      inspect(input, policy: policy).relativePath;

  _PathResolution inspect(
    String input, {
    required _PathLeafPolicy policy,
    String? authorityNotRegularDetail,
  }) {
    final components = _pathComponents(input);
    var current = root;
    for (var index = 0; index < components.length; index++) {
      final component = components[index];
      final isLeaf = index == components.length - 1;
      final siblings = _directoryChildren(current);
      final folded = _asciiFold(component);
      var exactSiblingPresent = false;
      for (final sibling in siblings) {
        if (sibling == component) exactSiblingPresent = true;
        if (_asciiFold(sibling) == folded && sibling != component) {
          throw _ConfigProblem(
            L10nEvidenceRejectionCode.invalidInputPath,
            'path-case-fold-collision',
            relativePath: input,
          );
        }
      }

      final next = p.join(current, component);
      final type = FileSystemEntity.typeSync(next, followLinks: false);
      if (type != FileSystemEntityType.notFound && !exactSiblingPresent) {
        throw _ConfigProblem(
          L10nEvidenceRejectionCode.invalidInputPath,
          'path-case-fold-collision',
          relativePath: input,
        );
      }
      if (type == FileSystemEntityType.link) {
        throw _ConfigProblem(
          L10nEvidenceRejectionCode.invalidInputPath,
          'path-symlink-component',
          relativePath: input,
        );
      }
      if (type == FileSystemEntityType.notFound) {
        if (_allowsMissing(policy)) {
          return _PathResolution(relativePath: input, exists: false);
        }
        throw _ConfigProblem(
          L10nEvidenceRejectionCode.invalidInputPath,
          policy == _PathLeafPolicy.requiredDirectory
              ? 'required-directory-missing'
              : 'required-file-missing',
          relativePath: input,
        );
      }
      if (!isLeaf) {
        if (type != FileSystemEntityType.directory) {
          throw _ConfigProblem(
            L10nEvidenceRejectionCode.invalidInputPath,
            'path-ancestor-not-directory',
            relativePath: input,
          );
        }
        current = next;
        continue;
      }

      switch (policy) {
        case _PathLeafPolicy.requiredDirectory:
          if (type != FileSystemEntityType.directory) {
            throw _ConfigProblem(
              L10nEvidenceRejectionCode.invalidInputPath,
              'required-directory-not-directory',
              relativePath: input,
            );
          }
        case _PathLeafPolicy.requiredFile:
          if (type != FileSystemEntityType.file) {
            throw _ConfigProblem(
              L10nEvidenceRejectionCode.invalidInputPath,
              authorityNotRegularDetail ?? 'required-file-not-regular',
              relativePath: input,
            );
          }
        case _PathLeafPolicy.optionalAuthorityFile:
          if (type != FileSystemEntityType.file) {
            throw _ConfigProblem(
              L10nEvidenceRejectionCode.invalidInputPath,
              authorityNotRegularDetail ?? 'required-file-not-regular',
              relativePath: input,
            );
          }
        case _PathLeafPolicy.outputDirectory:
          if (type != FileSystemEntityType.directory) {
            throw _ConfigProblem(
              L10nEvidenceRejectionCode.invalidInputPath,
              'path-ancestor-not-directory',
              relativePath: input,
            );
          }
        case _PathLeafPolicy.outputFile:
          if (type != FileSystemEntityType.file) {
            throw _ConfigProblem(
              L10nEvidenceRejectionCode.invalidInputPath,
              'output-leaf-not-regular',
              relativePath: input,
            );
          }
      }
      return _PathResolution(relativePath: input, exists: true);
    }
    throw StateError('validated path must contain a component');
  }

  List<String> _directoryChildren(String directory) {
    try {
      return Directory(directory)
          .listSync(followLinks: false)
          .map((entity) => p.basename(entity.path))
          .toList(growable: false);
    } on FileSystemException {
      throw const _ConfigProblem(
        L10nEvidenceRejectionCode.invalidInputPath,
        'configuration-path-inspection-failed',
      );
    }
  }
}

List<String> _pathComponents(String input) {
  if (input.isEmpty || input.startsWith('/') || input.startsWith('//')) {
    _invalidPathGrammar();
  }
  for (final codeUnit in input.codeUnits) {
    if (codeUnit < 0x20 || codeUnit > 0x7e) _invalidPathGrammar();
  }
  if (input.contains('\\') ||
      input.contains(':') ||
      input.contains('%') ||
      input.contains('?') ||
      input.contains('#')) {
    _invalidPathGrammar();
  }
  final components = input.split('/');
  if (components.any(
    (component) => component.isEmpty || component == '.' || component == '..',
  )) {
    _invalidPathGrammar();
  }
  return components;
}

Never _invalidPathGrammar() => throw const _ConfigProblem(
  L10nEvidenceRejectionCode.invalidInputPath,
  'path-grammar-invalid',
);

bool _allowsMissing(_PathLeafPolicy policy) => switch (policy) {
  _PathLeafPolicy.optionalAuthorityFile ||
  _PathLeafPolicy.outputDirectory ||
  _PathLeafPolicy.outputFile => true,
  _ => false,
};

void _validateOutputLocalizationFile(String value) {
  final components = _pathComponents(value);
  final safeFilename = RegExp(
    r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\.dart$',
  );
  if (components.length != 1 || !safeFilename.hasMatch(value)) {
    throw const _ConfigProblem(
      L10nEvidenceRejectionCode.invalidInputPath,
      'output-localization-file-invalid',
      relativePath: 'l10n.yaml',
    );
  }
}

String _joinPosix(String base, String child) {
  _pathComponents(child);
  return '$base/$child';
}

String _asciiFold(String value) {
  final folded = StringBuffer();
  for (final codeUnit in value.codeUnits) {
    folded.writeCharCode(
      codeUnit >= 0x41 && codeUnit <= 0x5a ? codeUnit + 0x20 : codeUnit,
    );
  }
  return folded.toString();
}

enum _ConfiguredPathKind { directory, file }

final class _ConfiguredPathRole {
  const _ConfiguredPathRole.directory(this.path)
    : kind = _ConfiguredPathKind.directory;
  const _ConfiguredPathRole.file(this.path) : kind = _ConfiguredPathKind.file;

  final String path;
  final _ConfiguredPathKind kind;
}

void _rejectConfiguredPathRoleCollisions(List<_ConfiguredPathRole> roles) {
  for (var firstIndex = 0; firstIndex < roles.length; firstIndex++) {
    final first = roles[firstIndex];
    final firstComponents = _pathComponents(first.path);
    for (
      var secondIndex = firstIndex + 1;
      secondIndex < roles.length;
      secondIndex++
    ) {
      final second = roles[secondIndex];
      final secondComponents = _pathComponents(second.path);
      final sharedLength = firstComponents.length < secondComponents.length
          ? firstComponents.length
          : secondComponents.length;
      var hasSharedPrefix = true;
      for (var index = 0; index < sharedLength; index++) {
        final firstComponent = firstComponents[index];
        final secondComponent = secondComponents[index];
        if (_asciiFold(firstComponent) != _asciiFold(secondComponent)) {
          hasSharedPrefix = false;
          break;
        }
        if (firstComponent != secondComponent) {
          throw _ConfigProblem(
            L10nEvidenceRejectionCode.invalidInputPath,
            'path-case-fold-collision',
            relativePath: second.path,
          );
        }
      }
      if (!hasSharedPrefix) continue;

      final samePath = firstComponents.length == secondComponents.length;
      final shorter = firstComponents.length < secondComponents.length
          ? first
          : second;
      if ((samePath &&
              (first.kind == _ConfiguredPathKind.file ||
                  second.kind == _ConfiguredPathKind.file)) ||
          (!samePath && shorter.kind == _ConfiguredPathKind.file)) {
        throw _ConfigProblem(
          L10nEvidenceRejectionCode.invalidInputPath,
          'configured-path-role-collision',
          relativePath: second.path,
        );
      }
    }
  }
}

final class _CapturedAuthority {
  const _CapturedAuthority(this.bytes);

  final ImmutableBytes bytes;
}

_CapturedAuthority? _captureAuthority(
  _SafeProjectPathWalker walker,
  String relativePath, {
  required bool required,
  required String notRegularDetail,
}) {
  final resolution = walker.inspect(
    relativePath,
    policy: required
        ? _PathLeafPolicy.requiredFile
        : _PathLeafPolicy.optionalAuthorityFile,
    authorityNotRegularDetail: notRegularDetail,
  );
  if (!resolution.exists) return null;
  try {
    return _CapturedAuthority(
      ImmutableBytes.copyOf(
        File(p.join(walker.root, relativePath)).readAsBytesSync(),
      ),
    );
  } on FileSystemException {
    throw _ConfigProblem(
      L10nEvidenceRejectionCode.invalidInputPath,
      'configuration-source-read-failed',
      relativePath: relativePath,
    );
  }
}

void _verifyAuthorityUnchanged(
  _SafeProjectPathWalker walker,
  String relativePath,
  _CapturedAuthority? expected, {
  required bool required,
  required String notRegularDetail,
}) {
  try {
    final current = _captureAuthority(
      walker,
      relativePath,
      required: required,
      notRegularDetail: notRegularDetail,
    );
    if ((current == null) != (expected == null) ||
        (current != null && !current.bytes.contentEquals(expected!.bytes))) {
      throw _ConfigProblem(
        L10nEvidenceRejectionCode.sourceDrift,
        'configuration-source-drift',
        relativePath: relativePath,
      );
    }
  } on _ConfigProblem catch (problem) {
    if (problem.code == L10nEvidenceRejectionCode.sourceDrift) rethrow;
    throw _ConfigProblem(
      L10nEvidenceRejectionCode.sourceDrift,
      'configuration-source-drift',
      relativePath: relativePath,
    );
  }
}

bool _containsCrLf(ImmutableBytes bytes) {
  for (var index = 0; index + 1 < bytes.length; index++) {
    if (bytes[index] == 0x0d && bytes[index + 1] == 0x0a) return true;
  }
  return false;
}

String _configurationIdentity({
  required _SchemaV1Table table,
  required FlutterMachineIdentity toolchain,
  required ImmutableBytes? yamlBytes,
  required String arbDirectory,
  required String templateArbPath,
  required String outputDirectory,
  required String baseOutputPath,
  required String? untranslatedMessagesPath,
  required String? headerFilePath,
  required String? header,
  required String outputClass,
  required List<String> preferredSupportedLocales,
  required bool useDeferredLoading,
  required bool requiredResourceAttributes,
  required bool nullableGetter,
  required bool format,
  required bool useEscaping,
  required bool suppressWarnings,
  required bool relaxSyntax,
  required bool useNamedParameters,
  required bool useCrLfOutputs,
}) {
  final framed = _IdentityFrames();
  framed.string('identity-format', 'l10n-generation-config-v1');
  framed.string('schema-table-id', table.tableId);
  framed.string('framework-version', toolchain.frameworkVersion.toString());
  framed.string('framework-revision', toolchain.frameworkRevision);
  framed.string('engine-revision', toolchain.engineRevision);
  framed.string('dart-sdk-version', toolchain.dartSdkVersion);
  framed.boolean('yaml-present', yamlBytes != null);
  if (yamlBytes != null) framed.bytes('yaml-bytes', yamlBytes.copy());
  framed.boolean('flutter-generate', true);
  framed.boolean('pubspec-has-crlf', useCrLfOutputs);
  framed.string('arb-directory', arbDirectory);
  framed.string('template-arb-path', templateArbPath);
  framed.string('output-directory', outputDirectory);
  framed.string('base-output-path', baseOutputPath);
  framed.nullableString('untranslated-messages-path', untranslatedMessagesPath);
  framed.nullableString('header-file-path', headerFilePath);
  framed.nullableString('header', header);
  framed.string('output-class', outputClass);
  framed.stringList('preferred-supported-locales', preferredSupportedLocales);
  framed.boolean('use-deferred-loading', useDeferredLoading);
  framed.boolean('required-resource-attributes', requiredResourceAttributes);
  framed.boolean('nullable-getter', nullableGetter);
  framed.boolean('format', format);
  framed.boolean('use-escaping', useEscaping);
  framed.boolean('suppress-warnings', suppressWarnings);
  framed.boolean('relax-syntax', relaxSyntax);
  framed.boolean('use-named-parameters', useNamedParameters);
  return sha256.convert(framed.takeBytes()).toString();
}

final class _IdentityFrames {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void string(String tag, String value) => bytes(tag, utf8.encode(value));

  void boolean(String tag, bool value) => string(tag, value ? 'true' : 'false');

  void nullableString(String tag, String? value) {
    boolean('$tag/present', value != null);
    if (value != null) string(tag, value);
  }

  void stringList(String tag, List<String> values) {
    string('$tag/count', values.length.toString());
    for (var index = 0; index < values.length; index++) {
      string('$tag/$index', values[index]);
    }
  }

  void bytes(String tag, List<int> value) {
    _raw(utf8.encode(tag));
    _raw(value);
  }

  void _raw(List<int> value) {
    _bytes
      ..add(utf8.encode(value.length.toString()))
      ..addByte(0)
      ..add(value)
      ..addByte(0);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

L10nGenerationConfigRejected _rejected(
  L10nEvidenceRejectionCode code,
  String detailCode, {
  String? relativePath,
}) => L10nGenerationConfigRejected([
  L10nEvidenceFailure(
    code: code,
    stage: _stage,
    detailCode: detailCode,
    relativePath: relativePath,
  ),
]);

final class _ConfigProblem implements Exception {
  const _ConfigProblem(this.code, this.detailCode, {this.relativePath});

  final L10nEvidenceRejectionCode code;
  final String detailCode;
  final String? relativePath;
}
