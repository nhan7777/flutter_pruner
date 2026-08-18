import 'app_localizations_en.dart';

class AppLocalizations {
  const AppLocalizations();

  String get welcome => 'Welcome';

  String greeting(String name) => 'Hello $name';

  String cartItem(int count) => '$count items';

  String selection(String gender) => gender;

  String lookup(String key) => switch (key) {
    'welcome' => welcome,
    _ => key,
  };

  String? lookupNullable(String key) => lookup(key);

  String normalize(String value) => value.trim();
}

final AppLocalizations generatedEnglish = AppLocalizationsEn();
