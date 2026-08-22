import 'callbacks.dart';

export 'src/reexport.dart' show publicReexport;

part 'src/public_part.dart';

void publicUsesImportedCallback() {
  unrelatedSibling();
  _privateSibling();
}

void _privateSibling() {}
