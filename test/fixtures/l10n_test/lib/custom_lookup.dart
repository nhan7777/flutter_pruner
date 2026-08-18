import 'l10n/app_localizations.dart';

const _welcomeKey = 'welcome';
const _unknownKey = 'unknown';

String constantLookup(AppLocalizations localizations) =>
    localizations.lookup(_welcomeKey);

String nullableConstantLookup(AppLocalizations localizations) =>
    localizations.lookupNullable(_welcomeKey) ?? '';

String normalizeValue(AppLocalizations localizations) =>
    localizations.normalize(_welcomeKey);

String unknownConstantLookup(AppLocalizations localizations) =>
    localizations.lookup(_unknownKey);

String dynamicLookup(AppLocalizations localizations, String key) =>
    localizations.lookup(key);
