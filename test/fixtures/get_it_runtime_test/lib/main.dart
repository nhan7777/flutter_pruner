import 'package:get_it/get_it.dart';

class RuntimeService {
  const RuntimeService();
}

void configure() {
  final getIt = GetIt.instance;
  getIt.registerSingleton(const RuntimeService());
  getIt.pushNewScope();
  getIt.registerLazySingleton<RuntimeService>(RuntimeService.new);
  getIt.enableRegisteringMultipleInstancesOfOneType();
  getIt.allowReassignment = true;
  getIt.allowRegisterMultipleImplementationsOfoneType = true;
  getIt.skipDoubleRegistration = true;
  getIt.reset();
  getIt.get<RuntimeService>();
  getIt.getAll<RuntimeService>();

  final helper = GetItHelper();
  helper.registerSingleton(const RuntimeService());
  helper.allowReassignment = true;
  helper.reset();
}
