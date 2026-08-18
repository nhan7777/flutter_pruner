import 'package:get_it/get_it.dart';

class DynamicService {
  const DynamicService();
}

void configure() {
  dynamic locator = GetIt.instance;
  locator.registerSingleton<DynamicService>(const DynamicService());
  locator.allowReassignment = true;
}
