// Deliberately lacks FlutterGen's historical generated-code header.
// Its conventional path and generated types must still be treated as an asset
// boundary.

class HeaderDriftAssets {
  static AssetGenImage get getterDrift =>
      AssetGenImage('assets/getter_drift.png');

  static AssetGenImage get wrapperDrift => _InnerAssets.wrapperDrift;

  // The source is intentionally opaque to the index. A caller must cause a
  // fail-closed blocker rather than letting every asset appear removable.
  static AssetGenImage get unresolved => buildFromRuntimeConfig();

  // Some generator versions expose a raw string instead of an asset wrapper.
  static String get rawGetter => 'assets/raw_getter.png';
}

class _InnerAssets {
  static const AssetGenImage wrapperDrift = AssetGenImage(
    'assets/wrapper_drift.png',
  );
}

AssetGenImage buildFromRuntimeConfig() =>
    AssetGenImage('assets/unresolved.png');

class AssetGenImage {
  const AssetGenImage(this._path);

  final String _path;

  String get path => _path;
}
