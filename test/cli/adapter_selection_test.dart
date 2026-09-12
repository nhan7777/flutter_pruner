import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/cli/adapter_selection.dart';
import 'package:flutter_pruner/src/cli/init_prompt.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory tempDir;
late ProjectContext project;

void main() {
  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('adapter_selection_test_');
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: selection_fixture
dependencies:
  flutter:
    sdk: flutter
''');
    project = await ProjectContext.load(tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('non-interactive selection returns only applicable adapters', () {
    final prompt = _FakePrompt(const [], isInteractive: false);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [
        _FakeAdapter('first', 'First', applicable: true),
        _FakeAdapter('second', 'Second', applicable: false),
        _FakeAdapter('third', 'Third', applicable: true),
      ],
    );

    expect(selection.resolve(project), {'first', 'third'});
    expect(prompt.responsesRead, 0);
  });

  test('explicit adapter IDs bypass interactive selection', () {
    final prompt = _FakePrompt(const []);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [
        _FakeAdapter('first', 'First'),
        _FakeAdapter('second', 'Second'),
      ],
    );

    expect(selection.resolve(project, requested: {'second'}), {'second'});
    expect(prompt.responsesRead, 0);
    expect(prompt.transcript, isEmpty);
  });

  test('interactive selection defaults to every applicable adapter', () {
    final prompt = _FakePrompt(['']);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [
        _FakeAdapter('first', 'First'),
        _FakeAdapter('hidden', 'Hidden', applicable: false),
        _FakeAdapter('third', 'Third'),
      ],
    );

    expect(selection.resolve(project), {'first', 'third'});
    expect(prompt.transcript, contains('[x] 1. First (first)'));
    expect(
      prompt.transcript,
      contains('[ ] 2. Hidden (hidden) (not detected)'),
    );
  });

  test('arrow picker toggles focused adapters and requires one selection', () {
    final prompt = _FakeKeyPrompt([
      PickerKey.down,
      PickerKey.space,
      PickerKey.enter,
    ]);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [
        _FakeAdapter('first', 'First'),
        _FakeAdapter('hidden', 'Hidden', applicable: false),
      ],
    );

    expect(selection.resolve(project), {'first', 'hidden'});
    expect(prompt.transcript, contains('Hidden'));
    expect(prompt.transcript, contains('not detected'));
    expect(prompt.transcript, contains('[x]'));
    expect(prompt.transcript, isNot(contains('\x1B[')));
  });

  test(
    'arrow picker renders styled tick and colors when ANSI is supported',
    () {
      final prompt = _FakeKeyPrompt([
        PickerKey.enter,
      ], supportsAnsiEscapes: true);
      final selection = AdapterSelection(
        prompt: prompt,
        adapters: const [_FakeAdapter('first', 'First')],
      );

      expect(selection.resolve(project), {'first'});
      expect(prompt.transcript, contains('[x]'));
      expect(prompt.transcript, contains('\x1B['));
      expect(prompt.transcript, contains('detected'));
    },
  );

  test('interactive selection accepts multiple numbers and adapter IDs', () {
    final prompt = _FakePrompt(['1, third']);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [
        _FakeAdapter('first', 'First'),
        _FakeAdapter('second', 'Second'),
        _FakeAdapter('third', 'Third'),
      ],
    );

    expect(selection.resolve(project), {'first', 'third'});
  });

  test('interactive selection rejects empty selection and asks again', () {
    final prompt = _FakePrompt(['none', '2']);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [
        _FakeAdapter('first', 'First'),
        _FakeAdapter('second', 'Second'),
      ],
    );

    expect(selection.resolve(project), {'second'});
    expect(
      prompt.transcript,
      contains('Select at least one adapter to continue.'),
    );
    expect(prompt.responsesRead, 2);
  });

  test('interactive selection rejects an unknown choice and asks again', () {
    final prompt = _FakePrompt(['99', 'first']);
    final selection = AdapterSelection(
      prompt: prompt,
      adapters: const [_FakeAdapter('first', 'First')],
    );

    expect(selection.resolve(project), {'first'});
    expect(prompt.transcript, contains('Unknown adapter selection: 99.'));
    expect(prompt.responsesRead, 2);
  });

  test('interactive selection treats EOF as cancellation', () {
    final selection = AdapterSelection(
      prompt: _FakePrompt([null]),
      adapters: const [_FakeAdapter('first', 'First')],
    );

    expect(
      () => selection.resolve(project),
      throwsA(isA<InitCancelledException>()),
    );
  });
}

final class _FakeAdapter extends AnalyzerAdapter {
  const _FakeAdapter(this.id, this.name, {this.applicable = true});

  @override
  final String id;

  @override
  final String name;

  final bool applicable;

  @override
  bool appliesTo(ProjectContext project) => applicable;

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {}
}

final class _FakePrompt implements InitPrompt {
  _FakePrompt(Iterable<String?> responses, {this.isInteractive = true})
    : _responses = List<String?>.from(responses);

  final List<String?> _responses;
  final StringBuffer _output = StringBuffer();
  var _index = 0;

  String get transcript => _output.toString();

  int get responsesRead => _index;

  @override
  final bool isInteractive;

  @override
  String? readLine() {
    final response = _index < _responses.length ? _responses[_index++] : null;
    if (response != null) _output.writeln();
    return response;
  }

  @override
  void write(String value) => _output.write(value);

  @override
  void writeln([String value = '']) => _output.writeln(value);
}

final class _FakeKeyPrompt
    implements InitPrompt, RawKeyInitPrompt, AnsiInitPrompt {
  _FakeKeyPrompt(Iterable<PickerKey?> keys, {this.supportsAnsiEscapes = false})
    : _keys = List<PickerKey?>.from(keys);

  final List<PickerKey?> _keys;
  final StringBuffer _output = StringBuffer();
  var _index = 0;

  String get transcript => _output.toString();

  @override
  final bool isInteractive = true;

  @override
  final bool supportsAnsiEscapes;

  @override
  String? readLine() => null;

  @override
  PickerKey? readPickerKey() => _index < _keys.length ? _keys[_index++] : null;

  @override
  void write(String value) => _output.write(value);

  @override
  void writeln([String value = '']) => _output.writeln(value);
}
