import 'l10n/app_localizations.dart';

final _topLevel = AppLocalizations();
final topLevelWelcome = _topLevel.welcome;

class Localizer {
  Localizer(this.localizations);

  final AppLocalizations localizations;

  String direct() => localizations.welcome;
  String placeholder() => localizations.greeting('Ada');
  String plural() => localizations.cartItem(2);
  String select() => localizations.selection('female');
}

extension LocalizationsX on AppLocalizations {
  String wrapped() => this.welcome;
}

extension BareLocalizationsX on AppLocalizations {
  String bareWrapped() => welcome;
}

AppLocalizations throughCascade(AppLocalizations localizations) =>
    localizations..greeting('Ada');

String dynamicReceiver() {
  dynamic l10n = AppLocalizations();
  return l10n.welcome as String;
}

String dynamicMethodReceiver() {
  dynamic l10n = AppLocalizations();
  return l10n.greeting('Ada') as String;
}

String dynamicCustomReceiver() {
  dynamic l10n = AppLocalizations();
  return l10n.lookup('welcome') as String;
}
