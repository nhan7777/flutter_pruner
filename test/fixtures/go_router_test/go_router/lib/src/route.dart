abstract class RouteBase {
  const RouteBase();
}

class GoRoute extends RouteBase {
  const GoRoute({
    required this.path,
    this.name,
    this.builder,
    this.routes = const <RouteBase>[],
  });

  final String path;
  final String? name;
  final Object? builder;
  final List<RouteBase> routes;
}

class ShellRoute extends RouteBase {
  const ShellRoute({this.routes = const <RouteBase>[]});

  final List<RouteBase> routes;
}
