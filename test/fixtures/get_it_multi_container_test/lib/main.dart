import 'package:get_it/get_it.dart';

class SecondaryService {
  const SecondaryService();
}

void configure() {
  final secondary = GetIt.asNewInstance();
  secondary.registerSingleton(const SecondaryService());

  final helper = GetItHelper.asNewInstance();
  helper.registerSingleton(const SecondaryService());
}
