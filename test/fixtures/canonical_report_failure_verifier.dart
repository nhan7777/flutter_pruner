import 'dart:io';

import 'package:path/path.dart' as p;

void main() {
  final counter = File('.canonical-report-verification-count');
  final count = counter.existsSync()
      ? int.tryParse(counter.readAsStringSync().trim()) ?? 0
      : 0;
  counter.writeAsStringSync('${count + 1}\n');
  if (count + 1 != 2) return;

  final quarantineRoot = Directory(p.join('.flutter_pruner', 'quarantine'));
  final runDirectory = quarantineRoot.listSync().whereType<Directory>().single;
  Directory(p.join(runDirectory.path, 'run-report.json')).createSync();
}
