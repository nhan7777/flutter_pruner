class GetIt {
  static final instance = GetIt();

  void registerSingleton<T>(T instance, {String? instanceName}) {}

  T get<T>({String? instanceName, Type? type}) =>
      throw UnsupportedError('fixture');

  Future<T> getAsync<T>({String? instanceName, Type? type}) async =>
      throw UnsupportedError('fixture');

  T? maybeGet<T>({String? instanceName, Type? type}) => null;

  Iterable<T> getAll<T extends Object>({
    dynamic param1,
    dynamic param2,
    bool fromAllScopes = false,
    String? onlyInScope,
  }) => const [];

  Future<Iterable<T>> getAllAsync<T extends Object>({
    dynamic param1,
    dynamic param2,
    bool fromAllScopes = false,
    String? onlyInScope,
  }) async => const [];

  bool isRegistered<T>({String? instanceName, Type? type}) => false;

  T call<T>({String? instanceName, Type? type}) =>
      throw UnsupportedError('fixture');
}
