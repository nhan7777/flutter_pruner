class ForeignContainer {
  void registerSingleton<T>(T value) {}

  T get<T>() => throw UnsupportedError('fixture');
}
