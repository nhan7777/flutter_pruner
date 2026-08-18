import 'package:get_it/get_it.dart';

class Foo {
  const Foo();
}

dynamic locator = GetIt.instance;

void configure() {
  GetIt.instance.registerSingleton<Foo>(const Foo());
}

void dynamicMemberLookup() {
  locator.get<Foo>();
}

void dynamicCallableLookup() {
  locator<Foo>();
}

void dynamicStateMutation() {
  locator.allowReassignment = true;
}
