import 'package:get_it/get_it.dart';

import 'foreign.dart';
import 'models.dart';

const emptyName = '';
const constantServiceType = Service;
final dynamicName = DateTime.now().toIso8601String();
final dynamicScopes = DateTime.now().isBefore(DateTime.now());
final runtimeType = DateTime.now().isBefore(DateTime.now())
    ? Service
    : NamedService;
final locator = GetIt.instance;
final topLevelService = locator.get<Service>();
final Service inferredService = locator.get();

void configure() {
  locator.registerSingleton(const Service());
  locator.registerSingleton(const NamedService(), instanceName: emptyName);
  locator.registerSingleton(const AllService());
  locator.registerSingleton(const AllService(), instanceName: 'all-named');
  locator.registerSingleton<DynamicService>(
    const DynamicService(),
    instanceName: dynamicName,
  );
  locator.registerSingleton<DuplicateService>(
    const DuplicateService(),
    instanceName: 'duplicate',
  );
  locator.registerSingleton<DuplicateService>(
    const DuplicateService(),
    instanceName: 'duplicate',
  );
}

Future<Service> resolveTopLevel() => locator.getAsync<Service>();

class Consumer {
  Consumer() : named = locator.get<NamedService>(instanceName: emptyName);

  final NamedService named;

  Service resolveMethods() {
    locator.maybeGet<Service>();
    locator.isRegistered<Service>();
    return locator<Service>();
  }

  Object resolveTypeOverride() => locator.get<Object>(type: Service);

  Object resolveConstTypeOverride() =>
      locator.get<Object>(type: constantServiceType);

  void resolveAll() {
    locator.getAll<AllService>();
    locator.getAllAsync<AllService>(fromAllScopes: false);
  }

  void unresolvedLookups<T>() {
    locator.get<T>();
    locator.get<Service>(instanceName: dynamicName);
    locator.get<Object>(type: runtimeType);
    locator.get<DuplicateService>(instanceName: 'duplicate');
    locator.get<DynamicService>();
    locator.get<MissingService>();
    locator.getAll<AllService>(fromAllScopes: true);
    locator.getAllAsync<AllService>(fromAllScopes: dynamicScopes);
    locator.getAll<AllService>(onlyInScope: 'named-scope', fromAllScopes: true);
    locator.getAllAsync<AllService>(onlyInScope: dynamicName);
    locator.getAll<AllService>(type: Service);
  }
}

void foreignLookup() {
  ForeignContainer().get<Service>();
  ForeignContainer().getAll<AllService>();
  ForeignCallable()<Service>();
}

void nestedNonRegistrationClosure() {
  final resolve = () => locator.get<Service>();
  resolve();
}
