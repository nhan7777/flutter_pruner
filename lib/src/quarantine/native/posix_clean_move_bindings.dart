import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32, VarArgs<()>);
typedef _OpenDart = int Function(Pointer<Uint8>, int);
typedef _OpenAtNative =
    Int32 Function(Int32, Pointer<Uint8>, Int32, VarArgs<()>);
typedef _OpenAtDart = int Function(int, Pointer<Uint8>, int);
typedef _MkdirAtNative = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _MkdirAtDart = int Function(int, Pointer<Uint8>, int);
typedef _RenameAtNative =
    Int32 Function(Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Uint32);
typedef _RenameAtDart =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _DescriptorBufferNative = Int32 Function(Int32, Pointer<Void>);
typedef _DescriptorBufferDart = int Function(int, Pointer<Void>);
typedef _DescriptorNative = Int32 Function(Int32);
typedef _DescriptorDart = int Function(int);
typedef _MallocNative = Pointer<Void> Function(UintPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

/// Direct libc/libSystem primitives needed by recoverable POSIX clean moves.
final class PosixCleanMoveBindings {
  /// Loads the supported host system library and required symbols.
  factory PosixCleanMoveBindings.open() {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError('POSIX clean move is unavailable.');
    }
    final library = Platform.isMacOS
        ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
        : DynamicLibrary.open('libc.so.6');
    return PosixCleanMoveBindings._(library);
  }

  PosixCleanMoveBindings._(DynamicLibrary library)
    : _openPath = library.lookupFunction<_OpenNative, _OpenDart>('open'),
      _openAt = library.lookupFunction<_OpenAtNative, _OpenAtDart>('openat'),
      _mkdirAt = library.lookupFunction<_MkdirAtNative, _MkdirAtDart>(
        'mkdirat',
      ),
      _renameAt = library.lookupFunction<_RenameAtNative, _RenameAtDart>(
        Platform.isMacOS ? 'renameatx_np' : 'renameat2',
      ),
      _stat = _lookupStat(library),
      _sync = library.lookupFunction<_DescriptorNative, _DescriptorDart>(
        'fsync',
      ),
      _close = library.lookupFunction<_DescriptorNative, _DescriptorDart>(
        'close',
      ),
      _allocate = library.lookupFunction<_MallocNative, _MallocDart>('malloc'),
      _release = library.lookupFunction<_FreeNative, _FreeDart>('free'),
      _errnoLocation = library
          .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
            Platform.isMacOS ? '__error' : '__errno_location',
          );

  final _OpenDart _openPath;
  final _OpenAtDart _openAt;
  final _MkdirAtDart _mkdirAt;
  final _RenameAtDart _renameAt;
  final _DescriptorBufferDart _stat;
  final _DescriptorDart _sync;
  final _DescriptorDart _close;
  final _MallocDart _allocate;
  final _FreeDart _release;
  final _ErrnoLocationDart _errnoLocation;

  /// Opens an absolute directory path.
  int openPath(Pointer<Uint8> path, int flags) => _openPath(path, flags);

  /// Opens one relative directory component.
  int openAt(int parent, Pointer<Uint8> component, int flags) =>
      _openAt(parent, component, flags);

  /// Creates one relative directory component.
  int mkdirAt(int parent, Pointer<Uint8> component, int mode) =>
      _mkdirAt(parent, component, mode);

  /// Renames one leaf relative to two retained parents with platform flags.
  int renameAtNoReplace(
    int sourceParent,
    Pointer<Uint8> source,
    int destinationParent,
    Pointer<Uint8> destination,
    int flags,
  ) => _renameAt(sourceParent, source, destinationParent, destination, flags);

  /// Reads stable descriptor metadata.
  int stat(int descriptor, Pointer<Void> target) => _stat(descriptor, target);

  /// Flushes file or directory metadata through a retained descriptor.
  int sync(int descriptor) => _sync(descriptor);

  /// Closes one descriptor exactly once.
  int close(int descriptor) => _close(descriptor);

  /// Current thread-local errno.
  int get errno => _errnoLocation().value;

  /// Allocates native transfer memory.
  Pointer<Uint8> allocateBytes(int length) {
    final pointer = _allocate(length).cast<Uint8>();
    if (pointer.address == 0) throw StateError('Native allocation failed.');
    return pointer;
  }

  /// Releases memory returned by [allocateBytes].
  void release(Pointer<Void> pointer) => _release(pointer);

  /// Runs [callback] with a temporary NUL-terminated UTF-8 string.
  T withCString<T>(String value, T Function(Pointer<Uint8>) callback) {
    final bytes = utf8.encode(value);
    if (bytes.contains(0)) throw ArgumentError.value(value, 'value');
    final pointer = allocateBytes(bytes.length + 1);
    try {
      pointer.asTypedList(bytes.length + 1)
        ..setRange(0, bytes.length, bytes)
        ..[bytes.length] = 0;
      return callback(pointer);
    } finally {
      release(pointer.cast<Void>());
    }
  }
}

_DescriptorBufferDart _lookupStat(DynamicLibrary library) {
  final symbols = Platform.isMacOS
      ? const [r'fstat$INODE64', 'fstat']
      : const ['fstat'];
  Object? failure;
  for (final symbol in symbols) {
    try {
      return library
          .lookupFunction<_DescriptorBufferNative, _DescriptorBufferDart>(
            symbol,
          );
    } on ArgumentError catch (error) {
      failure = error;
    }
  }
  throw ArgumentError('Required fstat capability is unavailable: $failure');
}
