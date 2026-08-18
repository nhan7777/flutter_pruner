import 'package:get_it/get_it.dart';

import 'foreign.dart';
import 'models_a.dart' as a;
import 'models_b.dart' as b;

const namedService = '';
final runtimeName = DateTime.now().toIso8601String();
final runtimeDependencies = <Type>[a.Service];
final runtimeLookupType = DateTime.now().isBefore(DateTime.now())
    ? a.Service
    : b.Service;
final locator = GetIt.instance;
final topLevelService = locator.get<b.Service>();

void configure() {
  final getIt = GetIt.instance;
  getIt.registerSingleton(a.Service());
  getIt.registerSingleton<a.Service>(a.Service(), instanceName: namedService);
  getIt.registerSingleton<a.Service>(a.Service(), instanceName: 'duplicate');
  getIt.registerSingleton<a.Service>(a.Service(), instanceName: 'duplicate');
  getIt.registerSingleton<b.Service>(b.Service());
  getIt.registerSingleton<a.Box<a.Service>>(const a.Box<a.Service>());
  getIt.registerSingleton<a.Box<List<a.Service>>>(
    const a.Box<List<a.Service>>(),
  );
  getIt.registerFactory(a.Service.new);
  getIt.registerCachedFactory<a.Service>(a.Service.new);
  getIt.registerFactoryParam<a.Service, int, String>((_, __) => a.Service());
  getIt.registerCachedFactoryParam<a.Service, int, String>(
    (_, __) => a.Service(),
  );
  getIt.registerFactoryAsync<a.Service>(() async => a.Service());
  getIt.registerCachedFactoryAsync<a.Service>(() async => a.Service());
  getIt.registerFactoryParamAsync<a.Service, int, String>(
    (_, __) async => a.Service(),
  );
  getIt.registerCachedFactoryParamAsync<a.Service, int, String>(
    (_, __) async => a.Service(),
  );
  getIt.registerSingletonIfAbsent<a.Service>(a.Service.new);
  getIt.registerSingletonWithDependencies<a.Box<a.Service>>(
    () => const a.Box<a.Service>(),
    dependsOn: const [a.Service],
  );
  getIt.registerSingletonAsync<a.Service>(
    () async => a.Service(),
    dependsOn: runtimeDependencies,
  );
  getIt.registerLazySingleton<a.Service>(a.Service.new);
  getIt.registerLazySingletonAsync<a.Service>(() async => a.Service());
  getIt.registerSingleton<a.Service>(a.Service(), instanceName: runtimeName);
  final helper = GetItHelper();
  helper.registerSingleton(a.Service());
  helper.allowReassignment = true;
  helper.reset();
  ForeignContainer().registerSingleton(a.Service());
}

b.Service resolveInTopLevelFunction() {
  final getIt = GetIt.instance;
  return getIt.get<b.Service>();
}

class Consumer {
  Consumer() : service = GetIt.instance.get<b.Service>();

  final b.Service service;

  b.Service resolveMethods() {
    final getIt = GetIt.instance;
    getIt.getAsync<b.Service>();
    getIt.maybeGet<b.Service>();
    getIt.isRegistered<b.Service>();
    return getIt<b.Service>();
  }

  Object resolveTypeOverride() => GetIt.instance.get<Object>(type: b.Service);

  void resolveAll() {
    GetIt.instance.getAll<a.Box<a.Service>>();
    GetIt.instance.getAllAsync<a.Box<a.Service>>();
  }

  void unresolvedLookups<T>() {
    GetIt.instance.get<T>();
    GetIt.instance.get<a.Service>(instanceName: runtimeName);
    GetIt.instance.get<Object>(type: runtimeLookupType);
    GetIt.instance.get<a.Service>(instanceName: 'duplicate');
    GetIt.instance.getAll<a.Service>();
  }
}

void foreignLookup() {
  ForeignContainer().get<a.Service>();
}
