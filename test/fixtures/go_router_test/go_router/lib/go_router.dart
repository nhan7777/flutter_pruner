/// Minimal stub mirroring the go_router 17.5.0 API surface the adapter reads.
class BuildContext {
  const BuildContext();
}

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

class GoRouter {
  const GoRouter({required this.routes});

  final List<RouteBase> routes;
}

extension GoRouterHelper on BuildContext {
  void go(String location, {Object? extra}) {}

  void goNamed(
    String name, {
    Map<String, String> pathParameters = const {},
    Object? extra,
  }) {}

  Future<T?> push<T extends Object?>(String location, {Object? extra}) async =>
      null;

  Future<T?> pushNamed<T extends Object?>(
    String name, {
    Map<String, String> pathParameters = const {},
    Object? extra,
  }) async => null;

  void replace(String location, {Object? extra}) {}

  void replaceNamed(
    String name, {
    Map<String, String> pathParameters = const {},
    Object? extra,
  }) {}

  void pushReplacement(String location, {Object? extra}) {}

  void pushReplacementNamed(
    String name, {
    Map<String, String> pathParameters = const {},
    Object? extra,
  }) {}

  bool canPop() => false;

  void pop<T extends Object?>([T? result]) {}

  String namedLocation(
    String name, {
    Map<String, String> pathParameters = const {},
  }) => name;
}
