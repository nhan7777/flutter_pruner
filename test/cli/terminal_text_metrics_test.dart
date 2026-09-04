import 'package:flutter_pruner/src/cli/terminal_text_metrics.dart';
import 'package:test/test.dart';

void main() {
  const metrics = TerminalTextMetrics();

  group('visibleWidth', () {
    test('measures printable terminal cells and ignores supported SGR', () {
      expect(metrics.visibleWidth('plain text'), 10);
      expect(metrics.visibleWidth('\x1B[31mred\x1B[0m'), 3);
      expect(metrics.visibleWidth('界'), 2);
      expect(metrics.visibleWidth('e\u0301'), 1);
    });

    test('keeps extended emoji clusters at their terminal cell width', () {
      expect(metrics.visibleWidth('😀'), 2);
      expect(metrics.visibleWidth('👍🏽'), 2);
      expect(metrics.visibleWidth('🇻🇳'), 2);
      expect(metrics.visibleWidth('👨‍👩‍👧‍👦'), 2);
      expect(metrics.visibleWidth('1️⃣'), 2);
      expect(metrics.visibleWidth('#\u20E3'), 2);
      expect(metrics.visibleWidth('©️'), 2);
      expect(metrics.visibleWidth('A\uFE0F'), 1);
      expect(metrics.visibleWidth('❤\uFE0E'), 1);
      expect(metrics.visibleWidth('❤\uFE0F'), 2);
      expect(metrics.visibleWidth('↔\uFE0E'), 1);
      expect(metrics.visibleWidth('⌨\uFE0E'), 1);
      expect(metrics.visibleWidth('▶\uFE0E'), 1);
      expect(metrics.visibleWidth('⬅\uFE0E'), 1);
      expect(metrics.visibleWidth('界\uFE0E'), 2);
      expect(metrics.visibleWidth('\u200D\uFE0F'), 0);
    });

    test('renders terminal-unsafe controls as visible text', () {
      const value = 'safe\nnext\x1B[2K\u061C\u200E\u200F';
      expect(metrics.visibleWidth(value), 35);
      expect(metrics.wrap(value, width: 160), [
        r'safe\nnext\x1B[2K\u061C\u200E\u200F',
      ]);
    });
  });

  group('wrap', () {
    test('wraps mixed-width text at 12, 13, 32, and 160 cells', () {
      const value = 'ab 界 e\u0301 😀 cd';

      expect(metrics.wrap(value, width: 12), ['ab 界 e\u0301 😀 c', 'd']);
      expect(metrics.wrap(value, width: 13), [value]);
      expect(metrics.wrap(value, width: 32), [value]);
      expect(metrics.wrap(value, width: 160), [value]);
    });

    test('splits an overlong word only between grapheme clusters', () {
      expect(metrics.wrap('e\u0301界😀x', width: 3), ['e\u0301界', '😀x']);
    });

    test('reapplies active SGR styling after a wrapped line reset', () {
      expect(metrics.wrap('\x1B[31mred blue\x1B[0m', width: 4), [
        '\x1B[31mred \x1B[0m',
        '\x1B[31mblue\x1B[0m',
      ]);
    });

    test(
      'preserves printable text in order across indentation and wrapping',
      () {
        final wrapped = metrics.wrap(
          '\x1B[36m界e\u0301😀 alpha\x1B[0m',
          width: 8,
          firstIndent: '> ',
          continuationIndent: '  ',
        );

        expect(wrapped, [
          '> \x1B[36m界e\u0301😀 \x1B[0m',
          '  \x1B[36malpha\x1B[0m',
        ]);
        expect(_printable(wrapped), '界e\u0301😀 alpha');
      },
    );

    test('clamps content to one cell after a wide indentation', () {
      expect(
        metrics.wrap(
          '界a',
          width: 1,
          firstIndent: '  ',
          continuationIndent: ' ',
        ),
        ['  界', ' a'],
      );
    });

    test('sanitizes and resets styled indents before printable content', () {
      final wrapped = metrics.wrap(
        'abcdefghijk',
        width: 16,
        firstIndent: '\x1B[34m>\x1B[2K ',
        continuationIndent: '\x1B[33m>\u200E ',
      );

      expect(wrapped, hasLength(2));
      expect(wrapped.first, startsWith('\x1B[34m>\\x1B[2K '));
      expect(wrapped.last, startsWith('\x1B[33m>\\u200E '));
      expect(wrapped.join(), isNot(contains('\x1B[2K')));
      expect(wrapped.join(), isNot(contains('\u200E')));
      expect(
        wrapped,
        everyElement(matches(RegExp(r'^\x1B\[[0-9;]*m.*\x1B\[0m[a-z]+$'))),
      );
    });
  });
}

String _printable(List<String> lines) => lines
    .map((line) => line.replaceFirst(RegExp(r'^(?:> |  )'), ''))
    .join()
    .replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
