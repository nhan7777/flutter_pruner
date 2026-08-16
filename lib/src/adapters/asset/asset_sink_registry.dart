import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

/// Identifies supported asset-loading APIs by resolved symbol identity.
///
/// Names alone are insufficient: an application method such as
/// `repository.loadProducts()` must never create an asset blocker.
class AssetSinkRegistry {
  /// Creates the built-in sink registry.
  const AssetSinkRegistry();

  /// Whether [node] invokes a supported asset-loading method.
  bool isMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    if (element is! ExecutableElement) return _isKnownUnresolvedMethod(node);
    final owner = element.enclosingElement?.name;
    final method = element.displayName;
    final library = element.library.firstFragment.source.uri.toString();

    if (library.startsWith('package:flutter/') && owner == 'AssetBundle') {
      return const {
        'load',
        'loadBuffer',
        'loadString',
        'loadStructuredData',
        'loadStructuredBinaryData',
      }.contains(method);
    }
    if (library.startsWith('package:flutter_svg/') && owner == 'SvgPicture') {
      return method == 'asset';
    }
    if (library.startsWith('package:lottie/') && owner == 'Lottie') {
      return method == 'asset';
    }
    return false;
  }

  /// Whether [node] invokes a supported asset-loading constructor.
  bool isInstanceCreation(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (element is! ConstructorElement) {
      final owner = node.constructorName.type.name.lexeme;
      final constructor = node.constructorName.name?.name ?? '';
      return (owner == 'Image' && constructor == 'asset') ||
          owner == 'AssetImage' ||
          owner == 'ExactAssetImage';
    }
    final owner = element.enclosingElement.name;
    final constructor = element.name ?? '';
    final library = element.library.firstFragment.source.uri.toString();
    if (!library.startsWith('package:flutter/')) return false;
    return (owner == 'Image' && constructor == 'asset') ||
        owner == 'AssetImage' ||
        owner == 'ExactAssetImage';
  }

  /// Whether [node] looks like an asset consumer that is not modeled exactly.
  ///
  /// External packages commonly expose APIs such as `RiveAnimation.asset` or
  /// `AssetSource`. We block these callers until a dedicated semantic adapter
  /// can prove their exact behavior.
  bool isPotentialMethodInvocation(MethodInvocation node) {
    if (isMethodInvocation(node)) return false;

    final method = node.methodName.name;
    if (_containsAssetHint(method)) return true;

    final element = node.methodName.element;
    if (element is ExecutableElement) {
      return _ownerSuggestsAssetLoading(element.enclosingElement?.name);
    }

    return _ownerSuggestsAssetLoading(_unresolvedTargetOwner(node.target));
  }

  /// Whether [node] looks like an asset constructor outside the exact model.
  bool isPotentialInstanceCreation(InstanceCreationExpression node) {
    if (isInstanceCreation(node)) return false;

    final element = node.constructorName.element;
    final owner = element is ConstructorElement
        ? element.enclosingElement.name
        : node.constructorName.type.name.lexeme;
    final constructor = element is ConstructorElement
        ? element.name ?? ''
        : node.constructorName.name?.name ?? '';
    return _containsAssetHint(constructor) || _ownerSuggestsAssetLoading(owner);
  }

  bool _isKnownUnresolvedMethod(MethodInvocation node) {
    final target = node.target;
    final owner = switch (target) {
      SimpleIdentifier(:final name) => name,
      PrefixedIdentifier(:final identifier) => identifier.name,
      _ => null,
    };
    final method = node.methodName.name;
    if (method == 'asset' &&
        (owner == 'Image' || owner == 'SvgPicture' || owner == 'Lottie')) {
      return true;
    }
    return owner == 'rootBundle' &&
        const {
          'load',
          'loadBuffer',
          'loadString',
          'loadStructuredData',
          'loadStructuredBinaryData',
        }.contains(method);
  }

  String? _unresolvedTargetOwner(Expression? target) => switch (target) {
    SimpleIdentifier(:final name) => name,
    PrefixedIdentifier(:final identifier) => identifier.name,
    PropertyAccess(:final propertyName) => propertyName.name,
    _ => null,
  };

  bool _ownerSuggestsAssetLoading(String? owner) {
    if (owner == null) return false;
    final normalized = owner.toLowerCase();
    return normalized.contains('asset') ||
        normalized.contains('svg') ||
        normalized.contains('lottie') ||
        normalized.contains('rive') ||
        normalized.contains('video') ||
        normalized.contains('audio');
  }

  bool _containsAssetHint(String value) =>
      value.toLowerCase().contains('asset');
}
