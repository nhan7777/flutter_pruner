import 'package:get_it/get_it.dart';

void unresolvedAliases() {
  sl.findAll<Foo>();
  sl.findFirstObjectRegistration<Foo>();
  sl.hasScope('scope');
  sl.checkLazySingletonInstanceExists<Foo>();
  sl.allReady();
  sl.allReadySync();
  sl.isReady<Foo>();
  sl.isReadySync<Foo>();
  sl.reset();
  sl.unregister<Foo>();
  sl.pushNewScope();
  di.allowReassignment = true;
}

void resolvedHelperCollisions() {
  final helper = GetItHelper();
  helper.findAll<int>();
  helper.findFirstObjectRegistration<int>();
  helper.hasScope('scope');
  helper.checkLazySingletonInstanceExists<int>();
  helper.allReady();
  helper.allReadySync();
  helper.isReady<int>();
  helper.isReadySync<int>();
  helper.reset();
  helper.unregister<int>();
  helper.pushNewScope();
  helper.allowReassignment = true;
}
