import 'package:get_it/get_it.dart';

void unresolvedRegistration() {
  sl.registerSingleton(MissingService());
  di.allowReassignment = true;
  sl.changeTypeInstanceName<Foo>();
  sl.resetLazySingletons();
}

void resolvedHelperCollision() {
  final helper = GetItHelper();
  helper.registerSingleton(0);
  helper.allowReassignment = true;
  helper.reset();
}
