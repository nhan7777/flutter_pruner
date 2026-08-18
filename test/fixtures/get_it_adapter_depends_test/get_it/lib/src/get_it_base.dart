typedef FactoryFunc<T> = T Function();

class GetIt {
  static final instance = GetIt();

  void registerSingleton<T>(T instance) {}

  void registerSingletonWithDependencies<T>(
    FactoryFunc<T> factoryFunc, {
    Iterable<Type>? dependsOn,
  }) {}
}
