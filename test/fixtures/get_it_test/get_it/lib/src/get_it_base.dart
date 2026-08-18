typedef FactoryFunc<T> = T Function();
typedef FactoryParam<T, P1, P2> = T Function(P1, P2);
typedef FactoryFuncAsync<T> = Future<T> Function();
typedef FactoryParamAsync<T, P1, P2> = Future<T> Function(P1?, P2?);

class GetIt {
  static final instance = GetIt();

  factory GetIt.asNewInstance() => GetIt();

  bool allowReassignment = false;
  bool allowRegisterMultipleImplementationsOfoneType = false;
  bool skipDoubleRegistration = false;

  void registerFactory<T>(FactoryFunc<T> factoryFunc, {String? instanceName}) {}
  void registerFactoryParam<T, P1, P2>(
    FactoryParam<T, P1, P2> factoryFunc, {
    String? instanceName,
  }) {}
  void registerFactoryAsync<T>(
    FactoryFuncAsync<T> factoryFunc, {
    String? instanceName,
  }) {}
  void registerFactoryParamAsync<T, P1, P2>(
    FactoryParamAsync<T, P1, P2> factoryFunc, {
    String? instanceName,
  }) {}
  void registerCachedFactory<T>(
    FactoryFunc<T> factoryFunc, {
    String? instanceName,
  }) {}
  void registerCachedFactoryParam<T, P1, P2>(
    FactoryParam<T, P1, P2> factoryFunc, {
    String? instanceName,
  }) {}
  void registerCachedFactoryAsync<T>(
    FactoryFuncAsync<T> factoryFunc, {
    String? instanceName,
  }) {}
  void registerCachedFactoryParamAsync<T, P1, P2>(
    FactoryParamAsync<T, P1, P2> factoryFunc, {
    String? instanceName,
  }) {}
  void registerSingleton<T>(T instance, {String? instanceName}) {}
  void registerSingletonAsync<T>(
    FactoryFuncAsync<T> factoryFunc, {
    String? instanceName,
    Iterable<Type>? dependsOn,
  }) {}
  void registerSingletonWithDependencies<T>(
    FactoryFunc<T> factoryFunc, {
    Iterable<Type>? dependsOn,
  }) {}
  void registerLazySingleton<T>(
    FactoryFunc<T> factoryFunc, {
    String? instanceName,
  }) {}
  void registerLazySingletonAsync<T>(
    FactoryFuncAsync<T> factoryFunc, {
    String? instanceName,
  }) {}
  T registerSingletonIfAbsent<T>(
    FactoryFunc<T> factoryFunc, {
    String? instanceName,
  }) => factoryFunc();

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

  void pushNewScope() {}
  Future<void> pushNewScopeAsync() async {}
  Future<void> popScope() async {}
  Future<bool> popScopesTill(String name, {bool inclusive = true}) async =>
      true;
  Future<void> dropScope(String name) async {}
  void enableRegisteringMultipleInstancesOfOneType() {}
  void reset() {}
}

/// A package-local helper whose names intentionally collide with GetIt.
class GetItHelper {
  bool allowReassignment = false;

  factory GetItHelper.asNewInstance() => GetItHelper();

  void registerSingleton<T>(T instance) {}

  void reset() {}

  List<T> findAll<T>() => const [];

  Object? findFirstObjectRegistration<T>() => null;

  bool hasScope(String scopeName) => false;

  bool checkLazySingletonInstanceExists<T>() => false;

  void allReady() {}

  bool allReadySync() => true;

  void isReady<T>() {}

  bool isReadySync<T>() => true;

  void unregister<T>() {}

  void pushNewScope() {}
}
