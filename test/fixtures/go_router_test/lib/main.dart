import 'package:go_router/go_router.dart';

part 'routes.g.dart';

final router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      routes: [
        GoRoute(path: 'details', name: 'details'),
        GoRoute(path: 'orphan'),
      ],
    ),
    GoRoute(path: '/dead'),
    GoRoute(path: '/settings', name: 'settings'),
    ShellRoute(routes: [GoRoute(path: '/shell-child')]),
    GoRoute(path: '/flags/:code'),
  ],
);

void openHome(BuildContext context) {
  context.go('/');
}

void openDetails(BuildContext context) {
  context.goNamed('details');
}

void openSettings(BuildContext context) {
  context.push('/settings');
}

void openComputed(BuildContext context, String code) {
  context.go('/flags/$code');
}

void openOpaque(BuildContext context, String location) {
  context.go(location);
}
