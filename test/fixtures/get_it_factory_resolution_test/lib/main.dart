import 'package:get_it/get_it.dart';

class Foo {
  const Foo();
}

class Bar {
  const Bar(Foo foo);
}

class Baz {
  const Baz(Foo foo);
}

void configure() {
  final getIt = GetIt.instance;
  getIt.registerSingleton<Foo>(const Foo());
  getIt.registerLazySingleton<Bar>(() => Bar(getIt<Foo>()));
  getIt.registerFactoryAsync<Baz>(() async => Baz(getIt<Foo>()));
}

void main() {
  configure();
}
