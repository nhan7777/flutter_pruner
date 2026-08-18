import 'package:get_it/get_it.dart';

class Present {
  const Present();
}

class ExactDependent {
  const ExactDependent();
}

class Duplicate {
  const Duplicate();
}

class AmbiguousDependent {
  const AmbiguousDependent();
}

class Missing {
  const Missing();
}

class MissingDependent {
  const MissingDependent();
}

void configure() {
  GetIt.instance.registerSingleton<Present>(const Present());
  GetIt.instance.registerSingletonWithDependencies<ExactDependent>(
    ExactDependent.new,
    dependsOn: const [Present],
  );
  GetIt.instance.registerSingleton<Duplicate>(const Duplicate());
  GetIt.instance.registerSingleton<Duplicate>(const Duplicate());
  GetIt.instance.registerSingletonWithDependencies<AmbiguousDependent>(
    AmbiguousDependent.new,
    dependsOn: const [Duplicate],
  );
  GetIt.instance.registerSingletonWithDependencies<MissingDependent>(
    MissingDependent.new,
    dependsOn: const [Missing],
  );
}
