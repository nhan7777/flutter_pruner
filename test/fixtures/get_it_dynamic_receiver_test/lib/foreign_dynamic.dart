class LocalLocator {}

void configureForeign(dynamic locator) {
  locator.registerSingleton<LocalLocator>(LocalLocator());
  locator.allowReassignment = true;
}
