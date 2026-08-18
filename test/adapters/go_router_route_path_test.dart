import 'package:flutter_pruner/src/adapters/go_router/route_path.dart';
import 'package:test/test.dart';

void main() {
  group('composeRoutePath', () {
    test('joins a parent root with a relative child', () {
      expect(composeRoutePath('/', 'details'), '/details');
    });

    test('joins nested relative segments', () {
      expect(composeRoutePath('/user', 'profile'), '/user/profile');
    });

    test('normalizes a child declared with a leading slash', () {
      expect(composeRoutePath('/user', '/profile'), '/user/profile');
    });

    test('keeps a top-level path when there is no parent', () {
      expect(composeRoutePath('', '/settings'), '/settings');
    });

    test('preserves path parameters verbatim', () {
      expect(composeRoutePath('/product', ':id'), '/product/:id');
    });

    test('collapses an empty child to the parent', () {
      expect(composeRoutePath('/user', ''), '/user');
    });

    test('renders the root path as a single slash', () {
      expect(composeRoutePath('', '/'), '/');
    });
  });

  group('ids', () {
    test('route node ids are scheme-prefixed and stable', () {
      expect(
        routeNodeId(packageName: 'app', fullPath: '/product/:id'),
        'route:app:/product/:id',
      );
    });

    test('name keys are distinct from path ids', () {
      expect(
        routeNameKey(packageName: 'app', name: 'details'),
        'route:app:#name=details',
      );
    });
  });
}
