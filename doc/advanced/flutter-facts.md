# Verified Flutter/Dart behaviour

Facts an adapter author needs in order to be correct. Every entry is verified
against primary documentation and carries a link. **Last verified 2026-08-10
against Flutter 3.44.7.**

If you find one of these is out of date, please open a PR — a stale fact here
turns into a false positive that deletes someone's file.

---

## Assets

### Declaration and logical keys

Assets are declared under `flutter: assets:` in `pubspec.yaml`. A directory
entry needs a trailing `/` and includes **only direct children, not
subdirectories**. The declared path is the logical key used by `Image.asset`,
`AssetImage` and `AssetBundle.load`.

<https://docs.flutter.dev/ui/assets/assets-and-images>

### Resolution variants have no logical key of their own

Files under `1.5x/`, `2.0x/`, `3.0x/`, `4.0x/` next to an asset are bundled
automatically and selected at runtime by device pixel ratio. **Only the parent
asset is declared, and only the parent path is ever referenced in code.**

An adapter that treats `assets/2.0x/logo.png` as an independently referenced
file will report it as unused and delete a needed variant. Always model variants
as children of their parent asset.

<https://docs.flutter.dev/ui/assets/assets-and-images>

### Transformers mean source size ≠ bundled size

An asset can declare `transformers:` so a Dart package rewrites it at build
time. **Only the transformed output is bundled**, and transformers chain — each
one receives the previous output.

```yaml
flutter:
  assets:
    - path: assets/logo.svg
      transformers:
        - package: vector_graphics_compiler
```

Consequence: a size figure computed from bytes on disk is not the size shipped.
Report source bytes as source bytes and measure binary impact from the release
artifact.

<https://docs.flutter.dev/ui/assets/asset-transformation>

### Asset manifest format

`AssetManifest.json` is deprecated (Flutter 3.19) in favour of
`AssetManifest.bin`, a Standard Message Codec binary; web uses
`AssetManifest.bin.json`. The manifest is the best ground truth for what was
actually bundled, but the format is an implementation detail that may change —
read it through `AssetManifest.loadFromAssetBundle()` rather than parsing bytes.

<https://docs.flutter.dev/release/breaking-changes/asset-manifest-dot-json>

### Package assets

Assets from a dependency are keyed `packages/<package_name>/<path>` (the
package's `lib/` is implicit). **Never propose deleting an asset owned by
another package.**

<https://docs.flutter.dev/ui/assets/assets-and-images>

### Build hooks do not provide data assets

Dart build hooks (`hook/build.dart`) support **code assets** — native libraries
reached through `@Native`. **Data assets are not supported in Flutter**; a build
fails with `Asset with type 'data_assets/data' is not a supported asset type`.

So asset inventory reads pubspec files only. Build hooks matter for native/FFI
analysis, not for asset discovery.

<https://dart.dev/tools/hooks> · <https://github.com/dart-lang/sdk/issues/55195>

---

## Reachability hazards

These are the ways something stays alive with **no Dart call site**. Each one is
a false positive waiting to happen.

### `@pragma('vm:entry-point')`

Preserves a declaration for invocation from native code through the Dart native
API. Forms include a bare annotation, a boolean, a const expression, and the
string variants `'get'`, `'call'`, `'set'`.

<https://github.com/dart-lang/sdk/blob/main/runtime/docs/compiler/aot/entry_point_pragma.md>

### Plugin background handlers — the highest-risk category

Several widely used plugins require a **top-level or static** function that
native code invokes in a fresh isolate via an opaque callback handle
(`PluginUtilities.getCallbackHandle` returns an int64 the platform stores). There
is no Dart→Dart edge at all.

| Plugin | Pattern |
|---|---|
| `firebase_messaging` | `FirebaseMessaging.onBackgroundMessage(handler)` |
| `workmanager` | `Workmanager().initialize(callbackDispatcher)` |
| `flutter_local_notifications` | `onDidReceiveBackgroundNotificationResponse` |
| `android_alarm_manager_plus` | `AndroidAlarmManager.oneShot/periodic(callback)` |

Treat these as protected roots, not as blockers.

<https://api.flutter.dev/flutter/dart-ui/PluginUtilities/getCallbackHandle.html>

### String-identified boundaries

- **Platform channels** identify their counterpart by channel name string:
  `MethodChannel('com.example/payments')`.
- **FFI** looks symbols up by name: `DynamicLibrary.lookup<T>('symbol')`,
  `@Native(symbol: 'name')`.
- **`NativeCallable`** hands a Dart function to C, which may be its only caller.

<https://api.dart.dev/stable/dart-ffi/DynamicLibrary/lookup.html>

### Deep links activate routes with no in-app caller

Android App Links and iOS Universal Links deliver a URI that the framework turns
into navigation. A declared route with no `context.go(...)` anywhere in the
source can still be the app's most-used entry point. Web targets need no
additional setup: route paths are read from the browser URL.

<https://docs.flutter.dev/ui/navigation/deep-linking>

### Web interop

`@JSExport` makes Dart callable from a JavaScript host page. `@JS()` external
members bind by string name.

<https://dart.dev/interop/js-interop>

### Isolates

`Isolate.spawn` and `compute` take a top-level or static function as a value. A
tear-off passed as an argument creates no call edge to the function body.

<https://api.flutter.dev/flutter/foundation/compute.html>

### Runtime string lookups

`Enum.values.byName('pending')` resolves an enum constant from a string, so a
value referenced nowhere in code can still be constructed from a server payload.

### `--dart-define` changes what is reachable

`bool.fromEnvironment` / `String.fromEnvironment` are const. The compiler folds
them and drops const-false branches **before** tree shaking. Two builds of
identical source with different defines have different reachable sets.

An engine must model defines as build conditions, or conservatively treat all
const-conditional branches as reachable. Picking one arbitrary define set and
treating it as global is how a false `SAFE` happens.

<https://api.dart.dev/stable/dart-core/bool/bool.fromEnvironment.html>

### Reflection is not a hazard here

`dart:mirrors` is unavailable in Flutter, because runtime reflection defeats
static tree shaking. `Function.apply` and `noSuchMethod` require a function
reference or an explicit override, so they do not create string→declaration
resolution.

---

## Routes

### `go_router` composes nested paths by segment

A child route is declared in its parent's `routes:` list. The full path comes
from `concatenatePaths(parentFullPath, route.path)`, which splits both sides on
`/`, drops empty segments and rejoins them under one leading slash. A
`ShellRoute` groups children without contributing a path segment.

```dart
GoRoute(
  path: '/',
  routes: [GoRoute(path: 'details')], // full path: /details
)
```

<https://github.com/flutter/packages/blob/go_router-v17.5.0/packages/go_router/lib/src/path_utils.dart>

### Navigation is exposed through `BuildContext`

`GoRouterHelper` adds `go`, `goNamed`, `push`, `pushNamed`, `replace`,
`replaceNamed`, `pushReplacement`, `pushReplacementNamed`, `pop`, `canPop` and
`namedLocation`. The named variants address a route by its `name:` argument,
not by path, so an adapter must index both.

Because these are extension members on `BuildContext`, a project method with
the same source name is a different element. Check the declaring library URI,
not only the method name.

<https://pub.dev/documentation/go_router/17.5.0/go_router/GoRouterHelper.html>

### `GoRoute` declares a path and optional name

`path` is a required `String`, `name` is an optional `String?`, and `routes` is
a `List<RouteBase>` that defaults to empty. Other constructor parameters
control builders, redirects, navigator placement, metadata, exit behavior and
case sensitivity; they do not replace the route identity.

<https://pub.dev/documentation/go_router/17.5.0/go_router/GoRoute-class.html>

---

## What the Dart analyzer already gives you

### `unreachable_from_main`

A **lint rule**, not a built-in diagnostic. Scope:

- applies only to **executable libraries** — those declaring `main`, or a
  top-level function annotated `@pragma('vm:entry-point')`
- covers **top-level declarations** only
- **no cross-package reachability**
- **not** in the `core` or `recommended` lint sets

Whether it recognises Flutter's `@Preview` as an entry point is not documented.

Useful as a test oracle where scope overlaps. Not a substitute for a project
graph.

<https://dart.dev/tools/linter-rules/unreachable_from_main>

### `package:analyzer` API stability

The package documents that it has **no clean public/internal API separation**
and that fixing this "will, unfortunately, require a large number of breaking
changes". Major versions move quickly, and the `Element` → `Element2`/`Fragment`
migration is ongoing.

Practical consequence for this repo: `pubspec.lock` is committed, the constraint
is tight, and CI tests more than one SDK.

<https://pub.dev/packages/analyzer>

---

## Localization

The synthetic `package:flutter_gen` output is **gone**. The change landed in
3.28.0-0.0.pre, stabilised in 3.32.0, and the docs state support is removed in
the following stable release.

Current behaviour:

- `generate: true` in `pubspec.yaml` is required
- generated localization sources are written into `lib/`, per `arb-dir` or
  `output-dir` in `l10n.yaml`
- `import 'package:flutter_gen/gen_l10n/app_localizations.dart'` is legacy

An l10n adapter resolves generated members at **real source paths**. Seeing a
`package:flutter_gen` import means the project has not migrated yet.

ARB key shapes: a plain key becomes a getter; a key with placeholders becomes a
**method with parameters**; plural and select messages become methods. `@key`
metadata and `@@locale` are not message keys.

<https://docs.flutter.dev/release/breaking-changes/flutter-generate-i10n-source>

---

## Size measurement

### `flutter build --analyze-size` constraints

| Constraint | Detail |
|---|---|
| Build mode | `--release` only |
| Android | exactly one ABI via `--target-platform`; incompatible with `--split-per-abi` |
| iOS | analyses arm64 symbols only |
| Flag conflict | cannot combine with `--split-debug-info` |
| Output | temp dir under the build directory; override with `--code-size-directory` |
| CI without certificates | `flutter build ios --no-codesign` works; `flutter build ipa --no-codesign` skips IPA creation entirely |

<https://docs.flutter.dev/tools/devtools/app-size>

### Upload size is not download size

Flutter documents that a default release build is an upload package and is "not
representative of your end-users' download size", because stores re-split by
architecture and density.

<https://docs.flutter.dev/perf/app-size>

### Tree shaking means dead Dart often costs zero bytes

The AOT compiler tree-shakes in profile and release builds. Deleting Dart code
that was already unreachable typically produces **no binary size change** —
the compiler had already removed it. Source cleanup and binary savings are
different claims and must be reported separately.

<https://docs.flutter.dev/tools/devtools/app-size>

### Release builds are not byte-reproducible

Timestamps, archive ordering, signing metadata and build UUIDs vary between
builds of identical source. A zero-byte regression gate fails on unchanged code.
Compare `--analyze-size` JSON, or allow a tolerance.

<https://docs.gradle.org/current/userguide/working_with_files.html#sec:reproducible_archives>

### Android shrinking defaults

- **Code shrinking (R8): on by default** in Flutter release builds.
- **Resource shrinking (`shrinkResources`): not documented as on by default**
  in Flutter. Standard Android requires `minifyEnabled` first. Do not assume
  unused Android resources were already removed — read the artifact.
- **R8 full mode is the default from AGP 8.0**, so anything reached by
  reflection needs an explicit keep rule.

<https://docs.flutter.dev/deployment/android> ·
<https://developer.android.com/topic/performance/app-optimization/full-mode>

### iOS size reporting

The App Thinning Size Report is **not produced for App Store distribution** —
only Ad Hoc, Enterprise and Development exports. For App Store builds, use build
metadata in App Store Connect.

<https://developer.apple.com/documentation/xcode/reducing-your-app-s-size>
