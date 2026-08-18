typedef FactoryFunc<T> = T Function();

class GetIt {
  static final instance = GetIt();

  void registerSingleton<T>(T instance, {String? instanceName}) {}

  T get<T>({String? instanceName, Type? type}) =>
      throw UnsupportedError('fixture');
}
