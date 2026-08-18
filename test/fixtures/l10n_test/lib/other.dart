class Other {
  String get welcome => 'not localization';

  String greeting(String name) => name;
}

String unrelatedWelcome(Other other) => other.welcome;

String localWelcome() {
  const welcome = 'local value';
  return welcome;
}
