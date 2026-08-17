import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

const profiles = <String, ({int dartFiles, int assets, int graphReferences})>{
  'small': (dartFiles: 200, assets: 100, graphReferences: 5000),
  'medium': (dartFiles: 1000, assets: 1000, graphReferences: 30000),
  'large': (dartFiles: 5000, assets: 5000, graphReferences: 200000),
  'xl': (dartFiles: 10000, assets: 20000, graphReferences: 500000),
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('profile', allowed: profiles.keys, mandatory: true)
    ..addOption('output', mandatory: true);
  final options = parser.parse(arguments);
  final profileName = options.option('profile')!;
  final profile = profiles[profileName]!;
  final output = Directory(p.absolute(options.option('output')!));
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError(
      'Output directory must be absent or empty: ${output.path}',
    );
  }

  await output.create(recursive: true);
  final lib = Directory(p.join(output.path, 'lib', 'src'));
  final assets = Directory(p.join(output.path, 'assets'));
  await lib.create(recursive: true);
  await assets.create(recursive: true);

  await File(p.join(output.path, 'pubspec.yaml')).writeAsString('''
name: flutter_pruner_perf_$profileName
publish_to: none
environment:
  sdk: ^3.9.0
''');
  await File(p.join(output.path, 'lib', 'main.dart')).writeAsString('''
import 'src/unit_00000.dart';

void main() => unit00000();
''');

  for (var index = 0; index < profile.dartFiles; index++) {
    final current = index.toString().padLeft(5, '0');
    final next = (index + 1).toString().padLeft(5, '0');
    final referenceCount = profile.graphReferences ~/ profile.dartFiles;
    final source = StringBuffer();
    if (index + 1 < profile.dartFiles) {
      source.writeln("import 'unit_$next.dart';");
      source.writeln();
    }
    source.writeln('void unit$current() {');
    source.writeln('  const values = <int>[1, 2, 3, 4, 5];');
    source.writeln(
      "  if (values.length == -1) throw StateError('unreachable');",
    );
    source.writeln('  helper${current}_000();');
    if (index + 1 < profile.dartFiles) source.writeln('  unit$next();');
    source.writeln('}');
    source.writeln();
    for (var reference = 0; reference < referenceCount; reference++) {
      final currentReference = reference.toString().padLeft(3, '0');
      final nextReference = (reference + 1).toString().padLeft(3, '0');
      final expression = reference + 1 < referenceCount
          ? 'helper${current}_$nextReference() + 1'
          : '0';
      source.writeln(
        'int helper${current}_$currentReference() => $expression;',
      );
    }
    source.writeln('void unused$current() {}');
    final currentLines = source.toString().split('\n').length - 1;
    for (var line = currentLines; line < 150; line++) {
      source.writeln('// deterministic parser padding ${line + 1}');
    }
    await File(
      p.join(lib.path, 'unit_$current.dart'),
    ).writeAsString(source.toString());
  }

  for (var index = 0; index < profile.assets; index++) {
    final name = index.toString().padLeft(5, '0');
    await File(p.join(assets.path, 'asset_$name.bin')).writeAsBytes([
      index & 0xff,
      (index >> 8) & 0xff,
      (index >> 16) & 0xff,
      (index >> 24) & 0xff,
    ]);
  }

  stdout.writeln(
    'Generated $profileName at ${output.path}: '
    '${profile.dartFiles} Dart files, ${profile.assets} assets, '
    '${profile.graphReferences} graph-reference seeds.',
  );
}
