import 'package:go_router/go_router.dart';

part 'routes.g.dart';

const detailsRouteName = 'details';
const settingsRoutePath = '/settings';

final router = GoRouter(
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
  ],
);

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
