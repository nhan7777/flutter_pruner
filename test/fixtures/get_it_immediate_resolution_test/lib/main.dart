import 'package:get_it/get_it.dart';

class Foo {
  const Foo();
}

class Immediate {
  const Immediate(Foo foo);
}

void configure() {
  final getIt = GetIt.instance;
  getIt.registerSingleton<Foo>(const Foo());
  getIt.registerSingletonIfAbsent<Immediate>(() => Immediate(getIt<Foo>()));
}

void main() {
  configure();
}
