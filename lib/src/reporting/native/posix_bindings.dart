import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32, VarArgs<()>);
typedef _OpenDart = int Function(Pointer<Uint8>, int);
typedef _OpenAtCreateNative =
    Int32 Function(Int32, Pointer<Uint8>, Int32, VarArgs<(Int32,)>);
typedef _OpenAtCreateDart = int Function(int, Pointer<Uint8>, int, int);
typedef _OpenAtExistingNative =
    Int32 Function(Int32, Pointer<Uint8>, Int32, VarArgs<()>);
typedef _OpenAtExistingDart = int Function(int, Pointer<Uint8>, int);
typedef _ReadNative = IntPtr Function(Int32, Pointer<Void>, UintPtr);
typedef _ReadDart = int Function(int, Pointer<Void>, int);
typedef _WriteNative = IntPtr Function(Int32, Pointer<Void>, UintPtr);
typedef _WriteDart = int Function(int, Pointer<Void>, int);
typedef _SeekNative = Int64 Function(Int32, Int64, Int32);
typedef _SeekDart = int Function(int, int, int);
typedef _FileDescriptorBufferNative = Int32 Function(Int32, Pointer<Void>);
typedef _FileDescriptorBufferDart = int Function(int, Pointer<Void>);
typedef _FileDescriptorNative = Int32 Function(Int32);
typedef _FileDescriptorDart = int Function(int);
typedef _MallocNative = Pointer<Void> Function(UintPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

/// Direct libc/libSystem surface required by immutable report persistence.
///
/// This deliberately does not look up any pathname mutation symbol.
final class PosixBindings {
  /// Loads the current supported host's system C library.
  factory PosixBindings.open() {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError('POSIX report capabilities are unavailable.');
    }
    final library = Platform.isMacOS
        ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
        : DynamicLibrary.open('libc.so.6');
    return PosixBindings._(library);
  }

  PosixBindings._(DynamicLibrary library)
    : _openPath = library.lookupFunction<_OpenNative, _OpenDart>('open'),
      _openAtCreate = library
          .lookupFunction<_OpenAtCreateNative, _OpenAtCreateDart>('openat'),
      _openAtExisting = library
          .lookupFunction<_OpenAtExistingNative, _OpenAtExistingDart>('openat'),
      _read = library.lookupFunction<_ReadNative, _ReadDart>('read'),
      _write = library.lookupFunction<_WriteNative, _WriteDart>('write'),
      _seek = library.lookupFunction<_SeekNative, _SeekDart>('lseek'),
      _stat = _lookupFileDescriptorBuffer(
        library,
        Platform.isMacOS ? const [r'fstat$INODE64', 'fstat'] : const ['fstat'],
      ),
      _statFileSystem = _lookupFileDescriptorBuffer(
        library,
        Platform.isMacOS
            ? const [r'fstatfs$INODE64', 'fstatfs']
            : const ['fstatfs'],
      ),
      _sync = library
          .lookupFunction<_FileDescriptorNative, _FileDescriptorDart>('fsync'),
      _closeDescriptor = library
          .lookupFunction<_FileDescriptorNative, _FileDescriptorDart>('close'),
      _allocate = library.lookupFunction<_MallocNative, _MallocDart>('malloc'),
      _release = library.lookupFunction<_FreeNative, _FreeDart>('free'),
      _errnoLocation = library
          .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
            Platform.isMacOS ? '__error' : '__errno_location',
          );

  /// Opens an anchored directory path.
  final _OpenDart _openPath;

  /// Opens or exclusively creates one leaf relative to a retained directory.
  final _OpenAtCreateDart _openAtCreate;

  /// Opens one existing leaf without passing a variadic mode argument.
  final _OpenAtExistingDart _openAtExisting;

  /// Reads bytes from a retained descriptor.
  final _ReadDart _read;

  /// Writes bytes to a retained descriptor.
  final _WriteDart _write;

  /// Repositions a retained descriptor.
  final _SeekDart _seek;

  /// Reads stable descriptor metadata.
  final _FileDescriptorBufferDart _stat;

  /// Reads the retained directory's filesystem identity.
  final _FileDescriptorBufferDart _statFileSystem;

  /// Flushes one retained descriptor.
  final _FileDescriptorDart _sync;

  /// Closes one retained descriptor.
  final _FileDescriptorDart _closeDescriptor;

  /// Allocates native transfer memory through the system C library.
  final _MallocDart _allocate;

  /// Releases native transfer memory through the system C library.
  final _FreeDart _release;

  final _ErrnoLocationDart _errnoLocation;

  /// Calls `open` without a variadic mode value.
  int openPath(Pointer<Uint8> path, int flags) => _openPath(path, flags);

  /// Calls `openat` with the promoted creation mode vararg.
  int openAtCreate(
    int directoryDescriptor,
    Pointer<Uint8> leaf,
    int flags,
    int mode,
  ) => _openAtCreate(directoryDescriptor, leaf, flags, mode);

  /// Calls `openat` without a variadic mode value.
  int openAtExisting(int directoryDescriptor, Pointer<Uint8> leaf, int flags) =>
      _openAtExisting(directoryDescriptor, leaf, flags);

  /// Calls `read` through a retained descriptor.
  int read(int descriptor, Pointer<Void> target, int length) =>
      _read(descriptor, target, length);

  /// Calls `write` through a retained descriptor.
  int write(int descriptor, Pointer<Void> source, int length) =>
      _write(descriptor, source, length);

  /// Calls `lseek` through a retained descriptor.
  int seek(int descriptor, int offset, int origin) =>
      _seek(descriptor, offset, origin);

  /// Calls `fstat` through a retained descriptor.
  int stat(int descriptor, Pointer<Void> target) => _stat(descriptor, target);

  /// Calls `fstatfs` through a retained directory descriptor.
  int statFileSystem(int descriptor, Pointer<Void> target) =>
      _statFileSystem(descriptor, target);

  /// Calls `fsync` through a retained descriptor.
  int sync(int descriptor) => _sync(descriptor);

  /// Calls `close` once; callers must not retry ambiguous close results.
  int closeDescriptor(int descriptor) => _closeDescriptor(descriptor);

  /// Current thread-local errno after a failed primitive.
  int get errno => _errnoLocation().value;

  /// Allocates [length] bytes or throws when the capability is unavailable.
  Pointer<Uint8> allocateBytes(int length) {
    final pointer = _allocate(length).cast<Uint8>();
    if (pointer.address == 0) {
      throw StateError('Native allocation failed.');
    }
    return pointer;
  }

  /// Releases memory obtained from [allocateBytes].
  void release(Pointer<Void> pointer) => _release(pointer);

  /// Calls [callback] with one temporary null-terminated UTF-8 string.
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

_FileDescriptorBufferDart _lookupFileDescriptorBuffer(
  DynamicLibrary library,
  List<String> symbols,
) {
  Object? lastError;
  for (final symbol in symbols) {
    try {
      return library.lookupFunction<
        _FileDescriptorBufferNative,
        _FileDescriptorBufferDart
      >(symbol);
    } on ArgumentError catch (error) {
      lastError = error;
    }
  }
  throw ArgumentError('Required system capability is unavailable: $lastError');
}
