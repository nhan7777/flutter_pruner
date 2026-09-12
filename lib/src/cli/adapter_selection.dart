import '../adapters/analyzer_adapter.dart';
import '../adapters/registry.dart';
import '../core/project/project_context.dart';
import 'init_prompt.dart';
import 'terminal_text_metrics.dart';

/// Detects applicable adapters and resolves the adapters selected for one run.
final class AdapterSelection {
  /// Creates a selector backed by [prompt].
  AdapterSelection({required this.prompt, List<AnalyzerAdapter>? adapters})
    : _adapters = adapters ?? AdapterRegistry.builtIn;

  /// Terminal used for interactive selection.
  final InitPrompt prompt;
  final List<AnalyzerAdapter> _adapters;

  /// Returns adapter IDs for [project].
  ///
  /// An explicit [requested] selection is authoritative. Otherwise only
  /// applicable adapters are retained, with an interactive checklist on a TTY
  /// and an automatic all-applicable selection for non-interactive callers.
  Set<String> resolve(ProjectContext project, {Set<String>? requested}) {
    if (requested != null) return Set.unmodifiable(requested);

    final applicableIds = _adapters
        .where((adapter) => adapter.appliesTo(project))
        .map((adapter) => adapter.id)
        .toSet();
    final allApplicable = Set<String>.unmodifiable(applicableIds);
    if (!prompt.isInteractive) return allApplicable;

    final rawPrompt = prompt is RawKeyInitPrompt
        ? prompt as RawKeyInitPrompt
        : null;
    if (rawPrompt != null) {
      return _resolveWithPicker(
        rawPrompt: rawPrompt,
        applicableIds: applicableIds,
      );
    }
    return _resolveWithLineInput(applicableIds: applicableIds);
  }

  Set<String> _resolveWithPicker({
    required RawKeyInitPrompt rawPrompt,
    required Set<String> applicableIds,
  }) {
    final selected = <String>{...applicableIds};
    var cursor = 0;
    var warningVisible = false;
    var firstRender = true;
    var previousLines = 0;

    int render() {
      final supportsAnsi =
          prompt is AnsiInitPrompt &&
          (prompt as AnsiInitPrompt).supportsAnsiEscapes;
      String style(String value, String code) =>
          supportsAnsi ? '$code$value\x1B[0m' : value;

      final adapterContents = <String>[
        for (var index = 0; index < _adapters.length; index++)
          () {
            final adapter = _adapters[index];
            final isApplicable = applicableIds.contains(adapter.id);
            final marker = index == cursor ? '>' : ' ';
            final box = selected.contains(adapter.id) ? '[x]' : '[ ]';
            final status = isApplicable ? 'detected' : 'not detected';
            return '$marker $box ${adapter.name}  $status';
          }(),
      ];
      const helpContents = [
        '↑↓ move    Space toggle    Enter confirm',
        '[x] selected    [ ] available    detected = project match',
      ];
      var contentWidth = 0;
      const metrics = TerminalTextMetrics();
      for (final content in [...adapterContents, ...helpContents]) {
        final width = metrics.visibleWidth(content);
        if (width > contentWidth) contentWidth = width;
      }
      final frameWidth = contentWidth + 4;
      String frameLine(String content) {
        const visiblePrefix = '│ ';
        const visibleSuffix = ' │';
        final innerWidth =
            frameWidth -
            metrics.visibleWidth(visiblePrefix) -
            metrics.visibleWidth(visibleSuffix);
        final contentVisible = metrics.visibleWidth(content);
        final pad = innerWidth - contentVisible;
        final padded = pad > 0 ? '$content${' ' * pad}' : content;
        return '$visiblePrefix$padded$visibleSuffix';
      }

      String styledFrameLine(String content, String code) =>
          supportsAnsi ? '\x1B[${code}m$content\x1B[0m' : content;

      final buffer = StringBuffer();
      buffer.writeln();
      buffer.writeln(style('◆ ADAPTERS', '\x1B[1m\x1B[36m'));
      buffer.writeln(style('  Choose the analyzers for this run', '\x1B[2m'));
      buffer.writeln(
        style('  Detected adapters are selected automatically', '\x1B[2m'),
      );
      buffer.writeln();
      buffer.writeln(styledFrameLine('┌${'─' * (frameWidth - 2)}┐', '1;36'));
      for (var index = 0; index < _adapters.length; index++) {
        final adapter = _adapters[index];
        final isApplicable = applicableIds.contains(adapter.id);
        final isSelected = selected.contains(adapter.id);
        final isCursor = index == cursor;
        final marker = isCursor ? '>' : ' ';
        final box = isSelected ? '[x]' : '[ ]';
        final status = isApplicable ? 'detected' : 'not detected';
        final plainContent = '$marker $box ${adapter.name}  $status';
        final frame = frameLine(plainContent);
        var rendered = frame;
        if (supportsAnsi) {
          rendered = isCursor
              ? styledFrameLine(frame, '1;30;46')
              : isSelected
              ? styledFrameLine(frame, '1;37')
              : styledFrameLine(frame, '2;37');
        }
        buffer.writeln(rendered);
      }
      buffer.writeln(styledFrameLine('└${'─' * (frameWidth - 2)}┘', '1;36'));
      buffer.writeln();
      buffer.writeln(styledFrameLine('┌${'─' * (frameWidth - 2)}┐', '1;35'));
      buffer.writeln(
        styledFrameLine(
          frameLine('↑↓ move    Space toggle    Enter confirm'),
          '1;33',
        ),
      );
      buffer.writeln(
        styledFrameLine(
          frameLine(
            '[x] selected    [ ] available    detected = project match',
          ),
          '1;36',
        ),
      );
      buffer.writeln(styledFrameLine('└${'─' * (frameWidth - 2)}┘', '1;35'));
      if (warningVisible) {
        buffer.writeln(
          style(
            '  ! Select at least one adapter to continue.',
            '\x1B[1m\x1B[33m',
          ),
        );
      }
      final text = buffer.toString();
      final lineCount = '\n'.allMatches(text).length;
      if (!firstRender && supportsAnsi && previousLines > 0) {
        prompt.write('\x1B[${previousLines}A\x1B[0J');
      }
      prompt.write(text);
      firstRender = false;
      previousLines = lineCount;
      return lineCount;
    }

    // Initial render.
    render();

    while (true) {
      final key = rawPrompt.readPickerKey();
      if (key == null) {
        render();
        continue;
      }
      switch (key) {
        case PickerKey.up:
          cursor = (cursor - 1 + _adapters.length) % _adapters.length;
          warningVisible = false;
          render();
        case PickerKey.down:
          cursor = (cursor + 1) % _adapters.length;
          warningVisible = false;
          render();
        case PickerKey.space:
          final id = _adapters[cursor].id;
          if (selected.contains(id)) {
            selected.remove(id);
          } else {
            selected.add(id);
          }
          warningVisible = false;
          render();
        case PickerKey.enter:
          if (selected.isEmpty) {
            warningVisible = true;
            render();
            continue;
          }
          return Set.unmodifiable(selected);
      }
    }
  }

  Set<String> _resolveWithLineInput({required Set<String> applicableIds}) {
    // Fallback for prompts without raw key support (tests).
    final selected = <String>{...applicableIds};

    prompt.writeln('Adapters:');
    for (var index = 0; index < _adapters.length; index++) {
      final adapter = _adapters[index];
      final isApplicable = applicableIds.contains(adapter.id);
      final isSelected = selected.contains(adapter.id);
      final box = isSelected ? '[x]' : '[ ]';
      final suffix = isApplicable ? '' : ' (not detected)';
      prompt.writeln(
        '$box ${index + 1}. ${adapter.name} (${adapter.id})$suffix',
      );
    }

    while (true) {
      prompt.write('Select adapters by number or ID (comma-separated) [all]: ');
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();

      final normalized = response.trim();
      if (normalized.isEmpty) {
        if (selected.isEmpty) {
          prompt.writeln('Select at least one adapter to continue.');
          continue;
        }
        return Set.unmodifiable(selected);
      }
      final tokens = normalized
          .split(',')
          .map((token) => token.trim())
          .where((token) => token.isNotEmpty)
          .toList(growable: false);
      if (tokens.length == 1 && tokens.single.toLowerCase() == 'none') {
        prompt.writeln('Select at least one adapter to continue.');
        continue;
      }

      final next = <String>{};
      String? invalidToken;
      for (final token in tokens) {
        final number = int.tryParse(token);
        if (number != null && number >= 1 && number <= _adapters.length) {
          next.add(_adapters[number - 1].id);
          continue;
        }
        final matchingId = _adapters
            .where((adapter) => adapter.id == token)
            .firstOrNull;
        if (matchingId != null) {
          next.add(matchingId.id);
          continue;
        }
        invalidToken = token;
        break;
      }

      if (invalidToken != null) {
        prompt.writeln('Unknown adapter selection: $invalidToken.');
        continue;
      }
      if (next.isEmpty) {
        prompt.writeln('Select at least one adapter to continue.');
        continue;
      }
      return Set.unmodifiable(next);
    }
  }
}
