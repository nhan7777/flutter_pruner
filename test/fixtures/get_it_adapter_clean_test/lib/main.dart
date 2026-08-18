import 'package:get_it/get_it.dart';

class Used {
  const Used();
}

class Unused {
  const Unused();
}

void configure() {
  GetIt.instance.registerSingleton<Used>(const Used());
  GetIt.instance.registerSingleton<Unused>(const Unused());
}

Used resolveUsed() => GetIt.instance.get<Used>();

void main() {}
