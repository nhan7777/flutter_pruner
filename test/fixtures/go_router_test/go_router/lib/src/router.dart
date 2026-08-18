import 'route.dart';

class BuildContext {
  const BuildContext();
}

class GoRouter {
  const GoRouter({required this.routes, this.redirect});

  final List<RouteBase> routes;
  final Object? redirect;
}
