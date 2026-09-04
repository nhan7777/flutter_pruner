import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/cli/formatters/html_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  test('inventory binds every reviewed saved HTML presentation value exactly', () {
    final outputs = [
      const HtmlFormatter().format(_report()),
      const HtmlFormatter().format(
        _report(command: RunCommand.apply, status: RunStatus.recoveryRequired),
      ),
      const HtmlFormatter().format(
        _report(command: RunCommand.apply, status: RunStatus.safeStopped),
      ),
      const HtmlFormatter().format(_report(partialApplied: true)),
    ];
    final inventory =
        jsonDecode(
              File(
                'test/cli/fixtures/cli_surface_inventory.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final entries = (inventory['surfaces']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((entry) => entry['command'] == 'saved html report')
        .toList(growable: false);
    final expected = entries
        .where(
          (entry) =>
              entry['artifactOracle'] == true &&
              (entry['id']! as String).startsWith('saved-html.oracle.'),
        )
        .map((entry) => entry['approvedTranscript']! as String)
        .toSet();
    void expectExactArtifactInventory(List<String> artifacts) {
      final observed = <String>{
        for (final output in artifacts)
          ..._extractHtmlPresentationValues(output),
      };
      expect(
        observed,
        expected,
        reason:
            'HTML presentation inventory must exactly cover visible text, '
            'action labels, and literal JavaScript presentation sinks; '
            'observed-only=${observed.difference(expected).toList()..sort()} '
            'expected-only=${expected.difference(observed).toList()..sort()}',
      );
    }

    expectExactArtifactInventory(outputs);

    final removed = [
      for (final output in outputs) output.replaceFirst('Copy command', ''),
    ];
    expect(
      () => expectExactArtifactInventory(removed),
      throwsA(isA<TestFailure>()),
      reason: 'removing rendered copy must fail the exact inventory oracle',
    );
    final added = [
      outputs.first.replaceFirst(
        '</body>',
        '<button type="button">Inventory mutation</button></body>',
      ),
      ...outputs.skip(1),
    ];
    expect(
      () => expectExactArtifactInventory(added),
      throwsA(isA<TestFailure>()),
      reason: 'adding rendered copy must fail the exact inventory oracle',
    );
    const analysisPassSink =
        r"`${labelFor('analysisPass', pass.purpose)} · ${duration(pass.elapsedMicros)}`";
    const novelAnalysisPassSink =
        r"`${labelFor('analysisPass', pass.purpose)} · ${novelInterpolation}`";
    expect(
      outputs.first,
      contains(analysisPassSink),
      reason: 'the mutation must target a real formatter presentation sink',
    );
    expect(
      _extractHtmlPresentationValues(outputs.first),
      contains('<html-label> · <html-row-value>'),
      reason: 'the unmutated sink must already have an exact inventory shape',
    );
    final novelTemplate = [
      for (final output in outputs)
        output.replaceFirst(analysisPassSink, novelAnalysisPassSink),
    ];
    expect(novelTemplate, everyElement(contains(novelAnalysisPassSink)));
    final legacyObserved = <String>{
      for (final output in novelTemplate)
        ..._extractHtmlPresentationValuesWithTemplateMarker(
          output,
          _legacyDefaultTemplateMarker,
        ),
    };
    expect(
      legacyObserved,
      expected,
      reason:
          'the former default marker would false-green this mutated artifact',
    );
    final currentObserved = <String>{
      for (final output in novelTemplate)
        ..._extractHtmlPresentationValues(output),
    };
    expect(
      currentObserved,
      contains('<html-label> · <unclassified-expression:novelInterpolation>'),
    );
    expect(
      () => expectExactArtifactInventory(novelTemplate),
      throwsA(isA<TestFailure>()),
      reason:
          'the current classifier must reject a novel interpolation in an '
          'otherwise registered artifact shape',
    );
  });

  test(
    'renders an offline report with script-safe embedded schema v3 JSON',
    () {
      final output = const HtmlFormatter().format(_report());

      expect(output, startsWith('<!doctype html>'));
      expect(
        output,
        contains('<script id="report-data" type="application/json">'),
      );
      expect(output, contains('"version":3'));
      expect(output, contains(r'Closing \u003c/script\u003e \u0026 safe'));
      expect(output, isNot(contains('</script><img')));
      expect(output, contains('Copy command'));
      expect(output, contains('Copy path'));
      expect(output, contains('Download JSON'));
      expect(output, contains('Verification'));
      expect(output, contains('Apply summary'));
      expect(output, contains('summary-grid'));
      expect(output, contains('technical-grid'));
      expect(output, contains('disclosure'));
      expect(output, contains('[hidden]'));
      expect(output, contains('findingOutcomes'));
      expect(output, contains('textContent'));
      expect(output, contains('Content-Security-Policy'));
      expect(output, contains('id="render-fallback"'));
      expect(output, contains('Static audit summary'));
      expect(output, contains('Closing &lt;/script&gt; &amp; safe'));
      expect(output, contains('"notRetained":false'));
      expect(output, contains('"retainedIn":["android","web"]'));
      expect(
        output,
        contains(
          '"auxiliaryRetainedIn":["aux:runtime:callback",'
          '"aux:test:support"]',
        ),
      );
      expect(output, contains('Retained by configured targets: android, web'));
      expect(
        output,
        contains(
          'Retained by auxiliary contexts: aux:runtime:callback, '
          'aux:test:support',
        ),
      );
      expect(output, contains("\$('render-fallback').hidden = true;"));
      expect(
        output,
        contains('main > :not(#render-fallback) { display:none!important; }'),
      );
      expect(output, contains('absolute local paths'));
      expect(output, contains('This package is audit-only'));
      expect(output, isNot(contains('innerHTML')));
      expect(output, isNot(contains('http://')));
      expect(output, isNot(contains('https://')));
    },
  );

  test('uses uppercase JSON tiers and automatic dry-run reports', () {
    final output = const HtmlFormatter().format(
      _report(confidence: Confidence.safe),
    );

    expect(output, contains('"confidence":"SAFE"'));
    expect(
      output,
      contains("const tiers = ['SAFE', 'HIGH', 'REVIEW', 'PROTECTED'];"),
    );
    expect(output, contains('normalizeTier(finding.confidence)'));
    expect(
      output,
      contains(
        r'flutter_pruner apply --project ${project} --dry-run${adapterArguments}',
      ),
    );
    expect(
      output,
      contains(
        r'flutter_pruner apply --project ${project} --dry-run${adapterArguments}',
      ),
    );
    expect(output, isNot(contains(r'--project ${project} --safe')));
    expect(output, isNot(contains(r'--project ${project} --high')));
    expect(output, isNot(contains('--report-output apply-preview.html')));
    expect(output, isNot(contains('--output rescan-report.html')));
    expect(
      output,
      contains('Transaction counters do not form a terminal partition'),
    );
    expect(output, contains('Source bytes removed (not app savings)'));
    expect(output, contains("['Confidence', snapshot.confidence]"));
    expect(output, contains('const analysisHealthy = finalPass !== null'));
    expect(output, contains('Final analysis graph has'));
    expect(
      output,
      contains('rerun the exact reviewed invocation from shell history'),
    );
    expect(
      output,
      contains(
        "const recoveryRequired = run.command === 'apply' && "
        "run.status === 'recoveryRequired'",
      ),
    );
    expect(output, contains('One or more transactions require recovery'));
    expect(output, contains('const adapterArguments ='));
    expect(output, contains("['Non-terminal', transactions.nonTerminal]"));
    expect(
      output,
      contains(
        "['Skipped because of a dependency', "
        'apply.findings && apply.findings.skippedDependency]',
      ),
    );
    expect(
      output,
      contains("['Declared', apply.actions && apply.actions.declared]"),
    );
    expect(
      output,
      contains("['Verification attempts', apply.verificationAttempts]"),
    );
    expect(output, contains('No — recovery required'));
    expect(output, contains('Finding audit detail'));
    expect(
      output,
      contains(
        "['Proposed action', labelFor('action', snapshot.proposedAction)]",
      ),
    );
    expect(output, contains("['Why not safe', snapshot.whyNotSafe]"));
    expect(output, contains("['Retained in', snapshot.retainedIn]"));
    expect(
      output,
      contains("['Auxiliary retained in', snapshot.auxiliaryRetainedIn]"),
    );
    expect(
      output,
      contains('const domainRows = detailRows(snapshot.details, snapshot)'),
    );
    expect(output, contains('Domain details'));
    expect(output, contains("labelFor('nodeKind',"));
    expect(output, contains("labelFor('predicate', key)"));
    expect(output, contains("labelFor('classification', reason)"));
    expect(
      output,
      contains(
        'measurementLabel(adapterId || measurement.adapterId, '
        "measurement.kind || 'measurement')",
      ),
    );
    expect(output, contains("labelFor('detail', key)"));
    expect(output, contains('Duplicate files'));
    expect(output, contains('Rule supports automatic fixes'));
    expect(output, contains('Unreachable in every configured target'));
    expect(output, contains('Not retained by any execution context'));
    expect(output, contains('Retained without exact reachability'));
    expect(output, contains('Target coverage is incomplete'));
    expect(output, contains('Source size'));
    expect(output, contains('Base asset size'));
    expect(output, contains('Target configurations'));
    expect(output, contains('Dart defines'));
    expect(output, contains("['Reason code'"));
    expect(output, contains('--on-accent:#101827'));
    expect(output, contains('color:var(--on-accent)'));
    expect(output, isNot(contains('flutter_pruner rollback')));
  });

  test('uses a flat, theme-aware report header color', () {
    final output = const HtmlFormatter().format(_report());

    expect(output, contains('--hero-bg:#1e3a5f'));
    expect(output, contains('--hero-bg:#1e293b'));
    expect(output, contains('.hero { background:var(--hero-bg)'));
    expect(output, contains('color:var(--hero-text)'));
    expect(output, contains('color:var(--hero-muted)'));
    expect(output, contains('color:var(--hero-warning)'));
    expect(output, isNot(contains('linear-gradient(')));
  });

  test('uses recovery warnings without stale success claims', () {
    final output = const HtmlFormatter().format(
      _report(command: RunCommand.apply, status: RunStatus.recoveryRequired),
    );

    expect(
      output,
      contains(
        'Recovery required: do not assume rollback restored the original state.',
      ),
    );
    expect(
      output,
      contains(
        'One or more transactions require recovery. '
        'Do not assume rollback restored the original state.',
      ),
    );
    expect(output, isNot(contains('rollback completed successfully')));
  });

  test(
    'distinguishes verified safe stops from legacy uncertain apply evidence',
    () {
      final safeStop = const HtmlFormatter().format(
        _report(command: RunCommand.apply, status: RunStatus.safeStopped),
      );
      final historicalPartial = const HtmlFormatter().format(
        _report(
          command: RunCommand.apply,
          status: RunStatus.safeStopped,
          partialApplied: true,
        ),
      );

      expect(safeStop, contains('Stopped safely — no mutation retained'));
      expect(
        safeStop,
        contains(
          'No mutation from this run was retained after verified rollback',
        ),
      );
      expect(safeStop, contains('Working-copy evidence'));
      expect(
        historicalPartial,
        contains(
          'legacy partialApplied flag marks an uncertain working-copy state',
        ),
      );
      expect(
        historicalPartial,
        contains('Working-copy state needs recovery attention'),
      );
      expect(
        historicalPartial,
        isNot(contains('Partial apply — inspect current state')),
      );
      expect(
        historicalPartial,
        isNot(contains('Treat the project as changed.')),
      );
    },
  );

  test('treats dangling roots as unhealthy in interactive and fallback views', () {
    final output = const HtmlFormatter().format(_report(danglingRoots: 1));

    expect(output, contains('"danglingRoots":1'));
    expect(output, contains('danglingRoots === 0'));
    expect(
      output,
      contains(
        'Final analysis graph has \${number(danglingRoots)} dangling root(s).',
      ),
    );
    expect(
      output,
      contains(
        'The final graph contains unresolved roots; automatic guidance is unsafe.',
      ),
    );
    expect(output, contains("['Graph dangling roots',"));
  });

  test('uses adapter-scoped custom labels and typed detail presentation', () {
    final output = const HtmlFormatter().format(
      _report(
        adapterReportDefinitions: [_routesPresentation, _localesPresentation],
      ),
    );

    expect(output, contains('Route catalog'));
    expect(output, contains('Route payload bytes'));
    expect(output, contains('Locale plural forms'));
    expect(output, contains('Serialized route payload size.'));
    expect(output, contains('const adapterCatalog = new Map'));
    expect(output, contains('findingPresentationFor(finding)'));
    expect(
      output,
      contains('adapterFor(finding && finding.reportingAdapterId)'),
    );
    expect(output, contains('const detailDefinition = (finding, key)'));
    expect(output, contains('detailRows(finding.details, finding)'));
    expect(
      output,
      contains('measurementLabel(adapterId || measurement.adapterId'),
    );
    expect(output, contains("definition && definition.valueType === 'bytes'"));
  });

  test('renders the accessible safety decision and findings workbench', () {
    final output = const HtmlFormatter().format(_report());

    expect(output, contains('<html lang="en" class="report-pending">'));
    expect(output, contains('href="#report-main"'));
    expect(output, contains('id="decision-banner"'));
    expect(output, contains('id="recovery-section"'));
    expect(output, contains('id="search" type="search"'));
    expect(output, contains('id="adapter-filter"'));
    expect(output, contains('id="blocker-filter"'));
    expect(output, contains('id="outcome-filter"'));
    expect(output, contains('id="load-more"'));
    expect(output, contains("theme.id = 'theme-toggle'"));
    expect(output, contains('@media (prefers-reduced-motion:reduce)'));
    expect(output, contains('min-height:44px'));
    expect(output, contains('const runFailed = ['));
    expect(output, contains('else if (runFailed)'));
    expect(output, contains('const graphFact ='));
    expect(output, contains('adapter failure(s)'));
    expect(output, contains('requestedIndex >= visibleLimit'));
    expect(output, contains("addEventListener('hashchange'"));
    expect(output, contains('scrollIntoView({ block: \'start\' })'));
    expect(output, contains('Copy finding link'));
    expect(output, contains('Printed finding snapshot:'));
  });

  test('extracts presentation copy from markup, CSS, and JavaScript sinks', () {
    const artifact = r'''
      <style>.disclosure::after { content:"View"; }</style>
      <section title="Safety title" aria-label="Safety label"><p>Fallback copy</p></section>
      <script>
        // Selectors and implementation identifiers are not presentation copy.
        const selector = '#report-main';
        const labels = Object.freeze({ status: { completed: 'Completed' } });
        const node = document.createElement('div');
        node.textContent = `Decision ${number(total)} complete`;
        make('button', 'button', 'Print report');
        append(host, 'p', 'notice', 'Action copy');
        empty(host, 'No findings were reported.');
        addMetricGroup(host, 'Transactions', [['Committed', 1]]);
        addList(host, 'Evidence', [], value);
        badges(host, ['SAFE', 'HIGH']);
        copyText(path, button, 'Path copied');
        announceCopy('Copy failed.');
        statusWarnings.push('Recovery required.');
        node.setAttribute('aria-label', 'Decision status');
      </script>
    ''';

    expect(
      _extractHtmlPresentationValues(artifact),
      containsAll(<String>{
        'View',
        'Safety title',
        'Safety label',
        'Fallback copy',
        'Completed',
        'Decision <html-count> complete',
        'Print report',
        'Action copy',
        'No findings were reported.',
        'Transactions',
        'Committed',
        'Evidence',
        'SAFE',
        'HIGH',
        'Path copied',
        'Copy failed.',
        'Recovery required.',
        'Decision status',
      }),
    );
    expect(
      _extractHtmlPresentationValues(artifact),
      isNot(contains('#report-main')),
    );
  });

  test('classifies only reviewed template expression families', () {
    expect(_templateMarker('number(total)'), 'html-count');
    expect(_templateMarker("labelFor('runStatus', status)"), 'html-label');
    expect(_templateMarker('report.run.exitCode'), 'html-exit-code');
    expect(_templateMarker('filterSummary.join(\' · \')'), 'html-summary');
    expect(
      _templateMarker('novelInterpolation'),
      'unclassified-expression:novelInterpolation',
    );
  });
}

/// Reads presentation values from the serialized artifact itself. It deliberately
/// does not receive the inventory. The tokenizer owns visible markup (including
/// the no-JavaScript fallback), presentation attributes, and CSS pseudo-content;
/// the JavaScript scanner owns only explicit rendering sinks.
Set<String> _extractHtmlPresentationValues(String output) {
  return _extractHtmlPresentationValuesWithTemplateMarker(
    output,
    _templateMarker,
  );
}

Set<String> _extractHtmlPresentationValuesWithTemplateMarker(
  String output,
  String Function(String expression) templateMarker,
) {
  final values = <String>{};
  _extractHtmlMarkupPresentationValues(output, values);
  for (final block in RegExp(
    r'<script(?![^>]*application/json)[^>]*>([\s\S]*?)</script>',
    caseSensitive: false,
  ).allMatches(output)) {
    _extractJavaScriptPresentationValues(
      block.group(1)!,
      values,
      templateMarker,
    );
  }
  return values;
}

void _extractHtmlMarkupPresentationValues(String output, Set<String> values) {
  for (final block in RegExp(
    r'<style\b[^>]*>([\s\S]*?)</style>',
    caseSensitive: false,
  ).allMatches(output)) {
    for (final content in RegExp(
      r'''\bcontent\s*:\s*(["'])((?:\\.|(?!\1)[\s\S])*)\1''',
    ).allMatches(block.group(1)!)) {
      _addPresentationValue(values, _decodeJavaScriptString(content.group(2)!));
    }
  }

  final stack = <_HtmlElement>[];
  final tags = RegExp(r'<(/?)([A-Za-z][A-Za-z0-9:-]*)([^>]*)>');
  var cursor = 0;
  for (final tag in tags.allMatches(output)) {
    if (!_inNonPresentationMarkup(stack)) {
      _addMarkupText(values, output.substring(cursor, tag.start), stack);
    }
    cursor = tag.end;
    final closing = tag.group(1) == '/';
    final name = tag.group(2)!.toLowerCase();
    if (closing) {
      for (var index = stack.length - 1; index >= 0; index--) {
        final element = stack.removeLast();
        if (element.name == name) break;
      }
      continue;
    }
    final attributes = _presentationAttributes(name, tag.group(3)!);
    for (final value in attributes.values) {
      _addPresentationValue(values, value);
    }
    if (!tag.group(0)!.endsWith('/>')) {
      stack.add(_HtmlElement(name, tag.group(3)!));
    }
  }
  if (!_inNonPresentationMarkup(stack)) {
    _addMarkupText(values, output.substring(cursor), stack);
  }
}

Map<String, String> _presentationAttributes(String element, String source) {
  const names = <String>{'title', 'aria-label', 'placeholder', 'alt', 'value'};
  final attributes = <String, String>{};
  for (final match in RegExp(
    r'''([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(["'])((?:\\.|(?!\2)[\s\S])*)\2''',
  ).allMatches(source)) {
    final name = match.group(1)!.toLowerCase();
    if (names.contains(name) &&
        !(name == 'value' &&
            const <String>{
              'option',
              'input',
              'select',
              'textarea',
            }.contains(element))) {
      attributes[name] = _decodeHtmlText(match.group(3)!);
    }
  }
  return attributes;
}

bool _inNonPresentationMarkup(List<_HtmlElement> stack) =>
    stack.any((element) => element.name == 'script' || element.name == 'style');

void _addMarkupText(
  Set<String> values,
  String source,
  List<_HtmlElement> stack,
) {
  final value = _normalizeFallbackValue(
    _decodeHtmlText(source).replaceAll(RegExp(r'\s+'), ' ').trim(),
    stack,
  );
  if (value != null) _addPresentationValue(values, value);
}

String? _normalizeFallbackValue(String value, List<_HtmlElement> stack) {
  if (value.isEmpty) return null;
  if (value.startsWith('<!')) return null;
  final inFallback = stack.any(
    (element) => element.attributes.contains('id="render-fallback"'),
  );
  if (!inFallback) return value;
  final inFallbackMeta = stack.any(
    (element) => element.attributes.contains('class="fallback-meta"'),
  );
  final inFallbackFindings = stack.any(
    (element) => element.attributes.contains('class="fallback-findings"'),
  );
  final inStrong = stack.any((element) => element.name == 'strong');
  if ((inFallbackMeta && !inStrong) ||
      (inFallbackFindings && !inStrong) ||
      value.startsWith('· ') ||
      value.contains('file:') ||
      value.startsWith('/')) {
    return '<html-fallback-data>';
  }
  if (inFallbackFindings && inStrong) return '<html-fallback-finding>';
  if (RegExp(
    r'^(?:\d+|\d+ · SAFE \d+ · HIGH \d+ · REVIEW \d+ · PROTECTED \d+)$',
  ).hasMatch(value)) {
    return '<html-fallback-data>';
  }
  if (value.startsWith('Retained by configured targets:')) {
    return 'Retained by configured targets: <list>';
  }
  if (value.startsWith('Retained by auxiliary contexts:')) {
    return 'Retained by auxiliary contexts: <list>';
  }
  return value;
}

void _extractJavaScriptPresentationValues(
  String script,
  Set<String> values,
  String Function(String expression) templateMarker,
) {
  final tokens = _lexJavaScript(script, templateMarker);
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (token.value == 'labels') {
      final open = _indexOfValue(tokens, '(', index + 1);
      if (open != null) {
        final close = _matchingDelimiter(tokens, open, '(', ')');
        if (close != null) _addLabelMapValues(tokens, open + 1, close, values);
      }
      continue;
    }
    if (index + 3 < tokens.length &&
        tokens[index + 1].value == '.' &&
        tokens[index + 2].value == 'textContent' &&
        tokens[index + 3].value == '=') {
      final end = _expressionEnd(tokens, index + 4);
      _addExpressionStrings(tokens, index + 4, end, values);
      continue;
    }
    if (token.value == 'statusWarnings' &&
        index + 3 < tokens.length &&
        tokens[index + 1].value == '.' &&
        tokens[index + 2].value == 'push' &&
        tokens[index + 3].value == '(') {
      final close = _matchingDelimiter(tokens, index + 3, '(', ')');
      if (close != null) {
        _addExpressionStrings(tokens, index + 4, close, values);
      }
      continue;
    }
    if (token.kind != _JsTokenKind.identifier ||
        index + 1 >= tokens.length ||
        tokens[index + 1].value != '(') {
      continue;
    }
    final close = _matchingDelimiter(tokens, index + 1, '(', ')');
    if (close == null) continue;
    final arguments = _splitArguments(tokens, index + 2, close);
    switch (token.value) {
      case 'make':
        _addArgumentStrings(arguments, 2, values);
      case 'append':
        _addArgumentStrings(arguments, 3, values);
      case 'empty':
      case 'addList':
        _addArgumentStrings(arguments, 1, values);
      case 'addMetricGroup':
        _addArgumentStrings(arguments, 1, values);
        _addArgumentStrings(arguments, 2, values);
      case 'announceCopy':
        _addArgumentStrings(arguments, 0, values);
      case 'badges':
        _addArgumentStrings(arguments, 1, values);
      case 'addRows':
        _addArgumentStrings(arguments, 1, values);
      case 'copyText':
        _addArgumentStrings(arguments, 2, values);
      case 'setAttribute':
        final attribute = arguments.isEmpty
            ? null
            : _argumentSingleString(arguments.first);
        if (arguments.length >= 2 &&
            attribute != null &&
            const <String>{
              'aria-label',
              'title',
              'placeholder',
              'alt',
              'value',
            }.contains(attribute)) {
          _addArgumentStrings(arguments, 1, values);
        }
    }
  }
}

void _addLabelMapValues(
  List<_JsToken> tokens,
  int start,
  int end,
  Set<String> values,
) {
  for (var index = start; index + 1 < end; index++) {
    if (tokens[index].value != ':') continue;
    final value = tokens[index + 1];
    if (value.kind == _JsTokenKind.string ||
        value.kind == _JsTokenKind.template) {
      _addPresentationValue(values, value.value);
    }
  }
}

void _addArgumentStrings(
  List<_JsArgument> arguments,
  int argument,
  Set<String> values,
) {
  if (argument >= arguments.length) return;
  _addExpressionStrings(
    arguments[argument].tokens,
    arguments[argument].start,
    arguments[argument].end,
    values,
  );
}

String? _argumentSingleString(_JsArgument argument) {
  if (argument.end - argument.start != 1) return null;
  final token = argument.tokens[argument.start];
  return token.kind == _JsTokenKind.string ? token.value : null;
}

void _addExpressionStrings(
  List<_JsToken> tokens,
  int start,
  int end,
  Set<String> values,
) {
  for (var index = start; index < end; index++) {
    final token = tokens[index];
    if (token.kind == _JsTokenKind.string ||
        token.kind == _JsTokenKind.template) {
      if (_isStructuralExpressionString(tokens, index, start)) continue;
      _addPresentationValue(values, token.value);
    }
  }
}

bool _isStructuralExpressionString(
  List<_JsToken> tokens,
  int index,
  int start,
) {
  if (index >= start + 2 &&
      tokens[index - 1].value == '=' &&
      tokens[index - 2].value == '=') {
    return true;
  }
  if (index >= start + 3 &&
      tokens[index - 1].value == '=' &&
      tokens[index - 2].value == '=' &&
      tokens[index - 3].value == '=') {
    return true;
  }
  if (index < start + 2 || tokens[index - 1].value != '(') return false;
  const names = <String>{
    'labelFor',
    'tierClass',
    'adapterFor',
    'detailDefinition',
    'findBlocker',
    'document',
  };
  return names.contains(tokens[index - 2].value);
}

int _expressionEnd(List<_JsToken> tokens, int start) {
  var depth = 0;
  for (var index = start; index < tokens.length; index++) {
    switch (tokens[index].value) {
      case '(':
      case '[':
      case '{':
        depth++;
      case ')':
      case ']':
      case '}':
        depth--;
      case ';':
        if (depth == 0) return index;
    }
  }
  return tokens.length;
}

int? _indexOfValue(List<_JsToken> tokens, String value, int start) {
  for (var index = start; index < tokens.length; index++) {
    if (tokens[index].value == value) return index;
  }
  return null;
}

int? _matchingDelimiter(
  List<_JsToken> tokens,
  int start,
  String open,
  String close,
) {
  var depth = 0;
  for (var index = start; index < tokens.length; index++) {
    if (tokens[index].value == open) depth++;
    if (tokens[index].value == close && --depth == 0) return index;
  }
  return null;
}

List<_JsArgument> _splitArguments(List<_JsToken> tokens, int start, int end) {
  final arguments = <_JsArgument>[];
  var argumentStart = start;
  var depth = 0;
  for (var index = start; index < end; index++) {
    final value = tokens[index].value;
    if (value == '(' || value == '[' || value == '{') depth++;
    if (value == ')' || value == ']' || value == '}') depth--;
    if (value == ',' && depth == 0) {
      arguments.add(_JsArgument(tokens, argumentStart, index));
      argumentStart = index + 1;
    }
  }
  if (argumentStart < end) {
    arguments.add(_JsArgument(tokens, argumentStart, end));
  }
  return arguments;
}

List<_JsToken> _lexJavaScript(
  String source,
  String Function(String expression) templateMarker,
) {
  final tokens = <_JsToken>[];
  var index = 0;
  while (index < source.length) {
    final code = source.codeUnitAt(index);
    if (_isWhitespace(code)) {
      index++;
    } else if (source.startsWith('//', index)) {
      final end = source.indexOf('\n', index + 2);
      index = end < 0 ? source.length : end + 1;
    } else if (source.startsWith('/*', index)) {
      final end = source.indexOf('*/', index + 2);
      index = end < 0 ? source.length : end + 2;
    } else if (source[index] == '\'' || source[index] == '"') {
      final parsed = _readQuotedJavaScriptString(source, index, source[index]);
      tokens.add(_JsToken(_JsTokenKind.string, parsed.value));
      index = parsed.next;
    } else if (source[index] == '`') {
      final parsed = _readJavaScriptTemplate(source, index, templateMarker);
      tokens.add(_JsToken(_JsTokenKind.template, parsed.value));
      index = parsed.next;
    } else if (_isIdentifierStart(code)) {
      final start = index++;
      while (index < source.length &&
          _isIdentifierPart(source.codeUnitAt(index))) {
        index++;
      }
      tokens.add(
        _JsToken(_JsTokenKind.identifier, source.substring(start, index)),
      );
    } else {
      tokens.add(_JsToken(_JsTokenKind.punctuation, source[index]));
      index++;
    }
  }
  return tokens;
}

_JsRead _readQuotedJavaScriptString(String source, int start, String quote) {
  final buffer = StringBuffer();
  var index = start + 1;
  while (index < source.length) {
    final character = source[index++];
    if (character == quote) break;
    if (character == '\\' && index < source.length) {
      buffer.write('\\${source[index++]}');
    } else {
      buffer.write(character);
    }
  }
  return _JsRead(_decodeJavaScriptString(buffer.toString()), index);
}

_JsRead _readJavaScriptTemplate(
  String source,
  int start,
  String Function(String expression) templateMarker,
) {
  final buffer = StringBuffer();
  var index = start + 1;
  while (index < source.length) {
    final character = source[index++];
    if (character == '`') break;
    if (character == '\\' && index < source.length) {
      buffer.write('\\${source[index++]}');
      continue;
    }
    if (character == r'$' && index < source.length && source[index] == '{') {
      final expressionStart = ++index;
      var depth = 1;
      while (index < source.length && depth > 0) {
        if (source[index] == '{') depth++;
        if (source[index] == '}') depth--;
        index++;
      }
      buffer.write(
        '<${templateMarker(source.substring(expressionStart, index - 1))}>',
      );
      continue;
    }
    buffer.write(character);
  }
  return _JsRead(_decodeJavaScriptString(buffer.toString()), index);
}

String _templateMarker(String expression) {
  final compact = expression.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.startsWith('number(') ||
      const <String>{
        'visibleFindings.length',
        'findings.length',
        '(report.findings || []).length',
      }.contains(compact)) {
    return 'html-count';
  }
  if (compact.startsWith('labelFor(')) return 'html-label';
  if (compact.startsWith('adapterName(')) return 'adapter';
  if (compact.startsWith('formatBytes(') ||
      compact.startsWith('formatMeasurement(')) {
    return 'formatted';
  }
  if (compact.startsWith('value(') ||
      compact.startsWith('duration(') ||
      compact.startsWith('readableCode(') ||
      compact.startsWith('humanizeIdentifier(') ||
      compact.startsWith('shellQuote(') ||
      const <String>{
        'label',
        'content',
        'status',
        'query',
        'key',
      }.contains(compact)) {
    return 'html-row-value';
  }
  if (compact == 'successMessage') return 'html-copy-result';
  if (const <String>{
    'report.run.exitCode',
    'step.exitCode',
  }.contains(compact)) {
    return 'html-exit-code';
  }
  if (compact == 'new Date(report.run.finishedAtUtc).toLocaleString()') {
    return 'html-timestamp';
  }
  if (compact == 'tier' || compact.startsWith('normalizeTier(')) {
    return 'html-tier';
  }
  if (compact == "filterSummary.join(' · ')") return 'html-summary';
  if (compact == 'nextCommand' ||
      compact == 'project' ||
      compact == 'adapterArguments') {
    return 'html-command';
  }
  if (compact ==
      "failedAdapters.map(adapter => adapter.name || adapter.id).join(', ')") {
    return 'html-report-value';
  }
  if (RegExp(
    r'^(?:report|finding|snapshot|outcome|target|measurement|attempt|step|diagnostic)\.',
  ).hasMatch(compact)) {
    return 'html-report-value';
  }
  return 'unclassified-expression:$compact';
}

String _legacyDefaultTemplateMarker(String expression) {
  final marker = _templateMarker(expression);
  return marker.startsWith('unclassified-expression:')
      ? 'html-row-value'
      : marker;
}

bool _isWhitespace(int code) =>
    code == 9 || code == 10 || code == 13 || code == 32;
bool _isIdentifierStart(int code) =>
    code == 36 ||
    code == 95 ||
    code >= 65 && code <= 90 ||
    code >= 97 && code <= 122;
bool _isIdentifierPart(int code) =>
    _isIdentifierStart(code) || code >= 48 && code <= 57;

void _addPresentationValue(Set<String> values, String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isNotEmpty) values.add(normalized);
}

class _HtmlElement {
  const _HtmlElement(this.name, this.attributes);

  final String name;
  final String attributes;
}

class _JsArgument {
  const _JsArgument(this.tokens, this.start, this.end);

  final List<_JsToken> tokens;
  final int start;
  final int end;
}

class _JsRead {
  const _JsRead(this.value, this.next);

  final String value;
  final int next;
}

class _JsToken {
  const _JsToken(this.kind, this.value);

  final _JsTokenKind kind;
  final String value;
}

enum _JsTokenKind { identifier, punctuation, string, template }

String _decodeHtmlText(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

String _decodeJavaScriptString(String value) => value
    .replaceAll(r"\'", "'")
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\u2014', '—');

RunReport _report({
  Confidence confidence = Confidence.review,
  List<AdapterReportDefinition> adapterReportDefinitions = const [],
  int danglingRoots = 0,
  RunCommand command = RunCommand.scan,
  RunStatus status = RunStatus.completed,
  bool partialApplied = false,
}) {
  final retainedOnly = confidence != Confidence.safe;
  final finding = Finding(
    ruleId: adapterReportDefinitions.isEmpty ? 'PRN-DART-001' : 'PRN-ROUTE-001',
    node: GraphNode(
      id: 'dart:test/lib/example.dart#symbol',
      kind: NodeKind.declaration,
      origin: Uri.file('/project/lib/example.dart'),
      displayName: 'example',
      metadata: const {'sharedDetail': 128},
    ),
    confidence: confidence,
    title: 'Closing </script> & safe',
    predicates: SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
      notRetained: !retainedOnly,
    ),
    retainedIn: retainedOnly ? const ['web', 'android'] : const [],
    auxiliaryRetainedIn: retainedOnly
        ? const ['aux:test:support', 'aux:runtime:callback']
        : const [],
    classificationReasons: retainedOnly
        ? const [ClassificationReason.retainedOnly]
        : const [],
    reportingAdapterId: adapterReportDefinitions.isEmpty ? null : 'routes',
  );
  return RunReport(
    identity: RunIdentity(
      id: 'run-html-test',
      command: command,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: status,
    exitCode: status == RunStatus.safeStopped ? 2 : 0,
    partialApplied: partialApplied,
    projectRoot: '/project',
    packageName: 'test',
    requestedAdapters: adapterReportDefinitions.isEmpty
        ? const ['dart']
        : adapterReportDefinitions
              .map((definition) => definition.adapterId)
              .toList(),
    adapterReportDefinitions: adapterReportDefinitions,
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: danglingRoots == 0
        ? const []
        : [
            AnalysisPassReport(
              id: 'analysis-001',
              purpose: AnalysisPassPurpose.initial,
              elapsedMicros: 1,
              nodeCount: 1,
              edgeCount: 0,
              rootCount: 1,
              recordedBlockerCount: 0,
              danglingEdgeCount: 0,
              danglingRootCount: danglingRoots,
              integrityByExecutionTarget: {
                'app:android': ExecutionTargetIntegrityReport(
                  id: 'app:android',
                  domain: 'configuredTarget',
                  complete: danglingRoots == 0,
                  danglingEdgeCount: 0,
                  danglingRootCount: danglingRoots,
                ),
              },
              adapterRuns: const [],
              findingStatistics: FindingStatistics.fromFindings([finding]),
              blockerStatistics: BlockerStatistics(
                recorded: 0,
                activeUnique: 0,
                affectedFindings: 0,
                byProducer: {},
              ),
              measurements: const [],
              exclusionPolicyVersion: 1,
              exclusionsByReason: const {},
            ),
          ],
    findings: [finding],
    diagnostics: const [],
  );
}

final _routesPresentation = AdapterReportDefinition(
  adapterId: 'routes',
  displayName: 'Route catalog',
  description: 'Route-specific report copy.',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.declaration,
      ruleId: 'PRN-ROUTE-001',
      title: 'Unlinked route callback',
      nodeLabel: 'Route callback',
      measurementKind: 'route-source-bytes',
      details: [
        AdapterReportDetailDefinition(
          key: 'sharedDetail',
          label: 'Route payload bytes',
          valueType: AdapterReportDetailValueType.bytes,
          description: 'Serialized route payload size.',
        ),
      ],
    ),
  ],
  measurements: [
    AdapterReportMeasurementDefinition(
      kind: 'route-source-bytes',
      label: 'Route source bytes',
      unit: 'bytes',
    ),
  ],
);

final _localesPresentation = AdapterReportDefinition(
  adapterId: 'locales',
  displayName: 'Locale catalog',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.localizationKey,
      ruleId: 'PRN-LOCALE-001',
      title: 'Orphan locale',
      nodeLabel: 'Locale key',
      details: [
        AdapterReportDetailDefinition(
          key: 'sharedDetail',
          label: 'Locale plural forms',
          valueType: AdapterReportDetailValueType.integer,
        ),
      ],
    ),
  ],
);
