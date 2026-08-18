import 'package:go_router/go_router.dart';

part 'routes.g.dart';

const detailsRouteName = 'details';
const settingsRoutePath = '/settings';
const duplicateRouteName = 'duplicate';

void main() {}

final router = GoRouter(
  redirect: (context, state) => AppRoutes.signup,
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      routes: [
        GoRoute(path: 'details', name: detailsRouteName),
        GoRoute(path: 'orphan'),
      ],
    ),
    GoRoute(path: '/dead'),
    GoRoute(path: settingsRoutePath, name: 'settings'),
    ShellRoute(routes: [GoRoute(path: '/shell-child')]),
    GoRoute(path: '/flags/:code'),
    GoRoute(path: '/duplicate-path', name: 'duplicatePathFirst'),
    GoRoute(path: '/duplicate-path', name: 'duplicatePathSecond'),
    GoRoute(path: '/duplicate-name-one', name: duplicateRouteName),
    GoRoute(path: '/duplicate-name-two', name: duplicateRouteName),
    GoRoute(path: '/signup'),
    GoRoute(path: '/search'),
    GoRoute(
      path: '/guides',
      routes: [GoRoute(path: 'faq')],
    ),
    GoRoute(path: '/login'),
  ],
);

abstract final class AppRoutes {
  static String get signup => '/signup';

  static String guide(String topic) => '/guides/$topic';

  static String search(String query) => '/search?query=$query';
}

class AppNavigator {
  AppNavigator(this.context);

  final BuildContext context;

  Future<void> push(String routeName) async {
    await context.push(routeName);
  }
}

Future<void> openThroughWrapper(AppNavigator navigator) async {
  await navigator.push(AppRoutes.signup);
  await navigator.push(AppRoutes.guide('faq'));
  await navigator.push(AppRoutes.search('tea'));
}

void openHome(BuildContext context) {
  context.go('/');
}

void openDetails(BuildContext context) {
  context.goNamed(detailsRouteName);
}

void openSettings(BuildContext context) {
  context.push('/settings?tab=profile');
}

void openFlag(BuildContext context) {
  context.go('/flags/us');
}

void openComputed(BuildContext context, String code) {
  context.go('/flags/$code');
}

void openOpaque(BuildContext context, String location) {
  context.go(location);
}

void openDynamicPath(dynamic context) {
  context.go('/settings');
}

void openDynamicName(dynamic context) {
  context.goNamed(detailsRouteName);
}

void openDynamicOpaque(dynamic context, String location) {
  context.push(location);
}

void openDynamicCascade(dynamic context) {
  context..go('/settings');
}

void openDynamicNullShortingCascade(dynamic context) {
  context?..pushNamed(detailsRouteName);
}

void openAmbiguousName(BuildContext context) {
  context.goNamed(duplicateRouteName);
}

class LocalNavigator {
  void go(String location) {}
}

void openLocalNavigation(LocalNavigator navigator) {
  navigator.go('/dead');
}
