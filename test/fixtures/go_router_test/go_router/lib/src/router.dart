import 'route.dart';

class BuildContext {
  const BuildContext();
}

class GoRouter {
  const GoRouter({required this.routes});

  final List<RouteBase> routes;
}
