import '../router.dart';

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
