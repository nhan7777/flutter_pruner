import 'app_en.bundle.dart';
import 'app_vi.bundle.dart';

class AppLocalizations {
  const AppLocalizations();

  String get live => 'Live';

  String get dead => 'Dead';

  String welcome(String name) => 'Welcome $name';
}

final english = AppLocalizationsEn();
final vietnamese = AppLocalizationsVi();
