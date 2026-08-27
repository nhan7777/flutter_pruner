import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../quarantine/native/windows_clean_open_mode.dart';

typedef _CreateFileNative =
    Pointer<Void> Function(
      Pointer<Uint16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    );
typedef _CreateFileDart =
    Pointer<Void> Function(
      Pointer<Uint16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    );
typedef _NtCreateFileNative =
    Int32 Function(
      Pointer<Pointer<Void>>,
      Uint32,
      Pointer<_WindowsObjectAttributes>,
      Pointer<_WindowsIoStatusBlock>,
      Pointer<Int64>,
      Uint32,
      Uint32,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
    );
typedef _NtCreateFileDart =
    int Function(
      Pointer<Pointer<Void>>,
      int,
      Pointer<_WindowsObjectAttributes>,
      Pointer<_WindowsIoStatusBlock>,
      Pointer<Int64>,
      int,
      int,
      int,
      int,
      Pointer<Void>,
      int,
    );
typedef _NtSetInformationFileNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<_WindowsIoStatusBlock>,
      Pointer<Void>,
      Uint32,
      Int32,
    );
typedef _NtSetInformationFileDart =
    int Function(
      Pointer<Void>,
      Pointer<_WindowsIoStatusBlock>,
      Pointer<Void>,
      int,
      int,
    );
typedef _TransferNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _TransferDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _HandleBoolNative = Int32 Function(Pointer<Void>);
typedef _HandleBoolDart = int Function(Pointer<Void>);
typedef _SetFilePointerNative =
    Int32 Function(Pointer<Void>, Int64, Pointer<Int64>, Uint32);
typedef _SetFilePointerDart =
    int Function(Pointer<Void>, int, Pointer<Int64>, int);
typedef _GetHandleInformationNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32);
typedef _GetHandleInformationDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _GetVolumeInformationNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint16>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint16>,
      Uint32,
    );
typedef _GetVolumeInformationDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint16>,
      int,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint16>,
      int,
    );
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();
typedef _HeapAllocNative =
    Pointer<Void> Function(Pointer<Void>, Uint32, UintPtr);
typedef _HeapAllocDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _HeapFreeNative = Int32 Function(Pointer<Void>, Uint32, Pointer<Void>);
typedef _HeapFreeDart = int Function(Pointer<Void>, int, Pointer<Void>);

final class _WindowsUnicodeString extends Struct {
  @Uint16()
  external int length;

  @Uint16()
  external int maximumLength;

  external Pointer<Uint16> buffer;
}

final class _WindowsObjectAttributes extends Struct {
  @Uint32()
  external int length;

  external Pointer<Void> rootDirectory;
  external Pointer<_WindowsUnicodeString> objectName;

  @Uint32()
  external int attributes;

  external Pointer<Void> securityDescriptor;
  external Pointer<Void> securityQualityOfService;
}

final class _WindowsIoStatusBlock extends Struct {
  external Pointer<Void> statusOrPointer;

  @UintPtr()
  external int information;
}

/// Raw Windows failure whose numeric code is never included in diagnostics.
final class WindowsNativeFailure implements Exception {
  /// Creates a failure from a Win32 or NT status code.
  const WindowsNativeFailure(
    this.operation,
    this.code, {
    this.ntStatus = false,
  });

  /// Stable native operation token.
  final String operation;

  /// Win32 error or NT status retained for stable category mapping.
  final int code;

  /// Whether [code] is an NT status rather than a Win32 error.
  final bool ntStatus;

  @override
  String toString() => 'Windows report capability failed; operation=$operation';
}

/// Metadata observed through one retained Windows handle.
final class WindowsHandleIdentityData {
  /// Creates decoded handle metadata.
  WindowsHandleIdentityData({
    required this.volumeSerial,
    required List<int> fileId,
    required this.byteLength,
    required this.isDirectory,
    required this.isReparsePoint,
  }) : fileId = List.unmodifiable(fileId);

  /// Volume serial returned by `FileIdInfo`.
  final int volumeSerial;

  /// Exact 128-bit Windows file ID.
  final List<int> fileId;

  /// Exact end-of-file length.
  final int byteLength;

  /// Whether the handle identifies a directory.
  final bool isDirectory;

  /// Whether the handle identifies a reparse point itself.
  final bool isReparsePoint;
}

/// Capability surface consumed by the Windows immutable report backend.
abstract interface class WindowsReportBindings {
  /// Opens one absolute directory without following its final reparse point.
  Pointer<Void> openDirectory(String path);

  /// Opens [component] as a directory relative to retained [parent].
  Pointer<Void> openRelativeDirectory(Pointer<Void> parent, String component);

  /// Opens or exclusively creates [leaf] relative to retained [parent].
  Pointer<Void> openRelative(
    Pointer<Void> parent,
    String leaf, {
    required bool create,
  });

  /// Writes at most [length] bytes and returns exact progress.
  int write(Pointer<Void> handle, Pointer<Void> source, int length);

  /// Reads at most [length] bytes and returns exact progress.
  int read(Pointer<Void> handle, Pointer<Void> target, int length);

  /// Flushes one retained handle.
  void flush(Pointer<Void> handle);

  /// Rewinds one retained handle.
  void rewind(Pointer<Void> handle);

  /// Reads stable file ID, length, type, and reparse state from [handle].
  WindowsHandleIdentityData identity(Pointer<Void> handle);

  /// Fails unless [directory] belongs to an NTFS volume.
  void verifyNtfs(Pointer<Void> directory);

  /// Closes one retained handle exactly once.
  void close(Pointer<Void> handle);

  /// Allocates zeroed process-heap bytes.
  Pointer<Uint8> allocateBytes(int length);

  /// Releases process-heap bytes from [allocateBytes].
  void release(Pointer<Void> pointer);
}

/// Direct Kernel32/Ntdll capabilities used by immutable report persistence and
/// the Windows recoverable-clean adapter.
///
/// The report-facing [WindowsReportBindings] interface exposes no file
/// deletion, movement, replacement, or directory-removal primitive.
final class WindowsBindings implements WindowsReportBindings {
  /// Loads Windows system DLL capabilities.
  factory WindowsBindings.open() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows report capabilities are unavailable.');
    }
    final kernel = DynamicLibrary.open('kernel32.dll');
    final ntdll = DynamicLibrary.open('ntdll.dll');
    return WindowsBindings._(kernel, ntdll);
  }

  WindowsBindings._(DynamicLibrary kernel, DynamicLibrary ntdll)
    : _createFile = kernel.lookupFunction<_CreateFileNative, _CreateFileDart>(
        'CreateFileW',
      ),
      _ntCreateFile = ntdll
          .lookupFunction<_NtCreateFileNative, _NtCreateFileDart>(
            'NtCreateFile',
          ),
      _ntSetInformationFile = ntdll
          .lookupFunction<
            _NtSetInformationFileNative,
            _NtSetInformationFileDart
          >('NtSetInformationFile'),
      _writeFile = kernel.lookupFunction<_TransferNative, _TransferDart>(
        'WriteFile',
      ),
      _readFile = kernel.lookupFunction<_TransferNative, _TransferDart>(
        'ReadFile',
      ),
      _flushFileBuffers = kernel
          .lookupFunction<_HandleBoolNative, _HandleBoolDart>(
            'FlushFileBuffers',
          ),
      _setFilePointer = kernel
          .lookupFunction<_SetFilePointerNative, _SetFilePointerDart>(
            'SetFilePointerEx',
          ),
      _getHandleInformation = kernel
          .lookupFunction<
            _GetHandleInformationNative,
            _GetHandleInformationDart
          >('GetFileInformationByHandleEx'),
      _getVolumeInformation = kernel
          .lookupFunction<
            _GetVolumeInformationNative,
            _GetVolumeInformationDart
          >('GetVolumeInformationByHandleW'),
      _closeHandle = kernel.lookupFunction<_HandleBoolNative, _HandleBoolDart>(
        'CloseHandle',
      ),
      _getLastError = kernel
          .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
            'GetLastError',
          ),
      _getProcessHeap = kernel
          .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
            'GetProcessHeap',
          ),
      _heapAllocate = kernel.lookupFunction<_HeapAllocNative, _HeapAllocDart>(
        'HeapAlloc',
      ),
      _heapFree = kernel.lookupFunction<_HeapFreeNative, _HeapFreeDart>(
        'HeapFree',
      ) {
    _heap = _getProcessHeap();
    if (_heap.address == 0) {
      throw const WindowsNativeFailure('get-process-heap', 0);
    }
  }

  static const _fileReadAttributes = 0x80;
  static const _fileTraverse = 0x20;
  static const _fileAddFile = 0x2;
  static const _fileAddSubdirectory = 0x4;
  static const _fileWriteAttributes = 0x100;
  static const _synchronize = 0x00100000;
  static const _genericRead = 0x80000000;
  static const _genericWrite = 0x40000000;
  static const _shareRead = 0x1;
  static const _shareWrite = 0x2;
  static const _shareDelete = 0x4;
  static const _delete = 0x00010000;
  static const _openExisting = 3;
  static const _backupSemantics = 0x02000000;
  static const _openReparsePoint = 0x00200000;
  static const _objectCaseInsensitive = 0x40;
  static const _fileAttributeNormal = 0x80;
  static const _fileOpen = 1;
  static const _fileCreate = 2;
  static const _fileOpenIf = 3;
  static const _synchronousIoNonAlert = 0x20;
  static const _directoryFile = 0x1;
  static const _nonDirectoryFile = 0x40;
  static const _moveBegin = 0;
  static const _fileStandardInfo = 1;
  static const _fileRenameInformation = 10;
  static const _fileAttributeTagInfo = 9;
  static const _fileIdInfo = 18;
  static const _reparsePointAttribute = 0x400;
  static const _heapZeroMemory = 0x8;

  final _CreateFileDart _createFile;
  final _NtCreateFileDart _ntCreateFile;
  final _NtSetInformationFileDart _ntSetInformationFile;
  final _TransferDart _writeFile;
  final _TransferDart _readFile;
  final _HandleBoolDart _flushFileBuffers;
  final _SetFilePointerDart _setFilePointer;
  final _GetHandleInformationDart _getHandleInformation;
  final _GetVolumeInformationDart _getVolumeInformation;
  final _HandleBoolDart _closeHandle;
  final _GetLastErrorDart _getLastError;
  final _GetProcessHeapDart _getProcessHeap;
  final _HeapAllocDart _heapAllocate;
  final _HeapFreeDart _heapFree;
  late final Pointer<Void> _heap;

  /// Opens one directory without following its final reparse point.
  @override
  Pointer<Void> openDirectory(String path) => withWideString(path, (widePath) {
    final handle = _createFile(
      widePath,
      _fileReadAttributes | _synchronize,
      _shareRead | _shareWrite,
      nullptr,
      _openExisting,
      _backupSemantics | _openReparsePoint,
      nullptr,
    );
    if (_isInvalidHandle(handle)) {
      throw WindowsNativeFailure('open-directory', _getLastError());
    }
    return handle;
  });

  /// Opens or exclusively creates one leaf relative to [parent].
  @override
  Pointer<Void> openRelative(
    Pointer<Void> parent,
    String leaf, {
    required bool create,
  }) => _openRelative(
    parent,
    leaf,
    desiredAccess:
        (create ? _genericRead | _genericWrite : _genericRead) | _synchronize,
    shareAccess: _shareRead,
    disposition: create ? _fileCreate : _fileOpen,
    options: _synchronousIoNonAlert | _nonDirectoryFile | _openReparsePoint,
    operation: create ? 'create-exclusive' : 'open-existing',
  );

  /// Opens one child directory relative to an already retained parent.
  @override
  Pointer<Void> openRelativeDirectory(Pointer<Void> parent, String component) =>
      _openRelative(
        parent,
        component,
        desiredAccess: _fileReadAttributes | _synchronize,
        shareAccess: _shareRead | _shareWrite,
        disposition: _fileOpen,
        options: _synchronousIoNonAlert | _directoryFile | _openReparsePoint,
        operation: 'open-directory-relative',
      );

  /// Opens one absolute directory for recoverable clean mutation.
  ///
  /// The returned handle is retained by the clean backend and is opened with
  /// write authority so its metadata can be flushed after a rename.
  Pointer<Void> openDirectoryForClean(String path) =>
      withWideString(path, (widePath) {
        final handle = _createFile(
          widePath,
          _genericRead | _genericWrite,
          _shareRead | _shareWrite | _shareDelete,
          nullptr,
          _openExisting,
          _backupSemantics | _openReparsePoint,
          nullptr,
        );
        if (_isInvalidHandle(handle)) {
          throw WindowsNativeFailure('open-clean-directory', _getLastError());
        }
        return handle;
      });

  /// Opens or creates one directory relative to [parent] with [mode].
  Pointer<Void> openRelativeDirectoryForClean(
    Pointer<Void> parent,
    String component, {
    required WindowsCleanDirectoryOpenMode mode,
  }) {
    final writable = switch (mode) {
      WindowsCleanDirectoryOpenMode.openWritable ||
      WindowsCleanDirectoryOpenMode.ensureWritable ||
      WindowsCleanDirectoryOpenMode.createExclusive => true,
      WindowsCleanDirectoryOpenMode.inspect ||
      WindowsCleanDirectoryOpenMode.renameSource => false,
    };
    final desiredAccess =
        _fileReadAttributes |
        _fileTraverse |
        _synchronize |
        (writable
            ? _fileAddFile | _fileAddSubdirectory | _fileWriteAttributes
            : 0) |
        (mode == WindowsCleanDirectoryOpenMode.renameSource ? _delete : 0);
    final disposition = switch (mode) {
      WindowsCleanDirectoryOpenMode.ensureWritable => _fileOpenIf,
      WindowsCleanDirectoryOpenMode.createExclusive => _fileCreate,
      WindowsCleanDirectoryOpenMode.inspect ||
      WindowsCleanDirectoryOpenMode.openWritable ||
      WindowsCleanDirectoryOpenMode.renameSource => _fileOpen,
    };
    final operation = switch (mode) {
      WindowsCleanDirectoryOpenMode.inspect => 'open-clean-directory-relative',
      WindowsCleanDirectoryOpenMode.openWritable =>
        'open-clean-writable-directory',
      WindowsCleanDirectoryOpenMode.renameSource => 'open-clean-rename-source',
      WindowsCleanDirectoryOpenMode.ensureWritable => 'ensure-clean-directory',
      WindowsCleanDirectoryOpenMode.createExclusive => 'create-clean-directory',
    };
    return _openRelative(
      parent,
      component,
      desiredAccess: desiredAccess,
      shareAccess: _shareRead | _shareWrite | _shareDelete,
      disposition: disposition,
      options: _synchronousIoNonAlert | _directoryFile | _openReparsePoint,
      operation: operation,
    );
  }

  /// Renames the exact open [source] below [destinationParent].
  ///
  /// `ReplaceIfExists` is deliberately false, so an existing destination is
  /// a hard native failure rather than an overwrite.
  void renameDirectoryNoReplace(
    Pointer<Void> source,
    Pointer<Void> destinationParent,
    String destinationLeaf,
  ) {
    if (destinationLeaf.isEmpty || destinationLeaf.codeUnits.contains(0)) {
      throw ArgumentError.value(destinationLeaf, 'destinationLeaf');
    }
    final nameBytes = destinationLeaf.codeUnits.length * 2;
    final is64Bit = sizeOf<IntPtr>() == 8;
    final nameOffset = is64Bit ? 20 : 12;
    // FILE_RENAME_INFORMATION includes one WCHAR plus trailing ABI alignment.
    // NtSetInformationFile accepts the retained destination-directory handle;
    // SetFileInformationByHandle does not reliably preserve that relative
    // RootDirectory contract and can reject it as an invalid parameter.
    final structureSize = is64Bit ? 24 : 16;
    final bufferSize = structureSize + nameBytes;
    final status = allocateBytes(
      sizeOf<_WindowsIoStatusBlock>(),
    ).cast<_WindowsIoStatusBlock>();
    try {
      final buffer = allocateBytes(bufferSize);
      try {
        final bytes = buffer.asTypedList(bufferSize);
        final data = bytes.buffer.asByteData();
        bytes[0] = 0; // FILE_RENAME_INFORMATION.ReplaceIfExists = FALSE.
        if (is64Bit) {
          data.setUint64(8, destinationParent.address, Endian.host);
          data.setUint32(16, nameBytes, Endian.host);
        } else {
          data.setUint32(4, destinationParent.address, Endian.host);
          data.setUint32(8, nameBytes, Endian.host);
        }
        (buffer + nameOffset)
            .cast<Uint16>()
            .asTypedList(destinationLeaf.codeUnits.length)
            .setAll(0, destinationLeaf.codeUnits);
        final ntStatus = _ntSetInformationFile(
          source,
          status,
          buffer.cast<Void>(),
          bufferSize,
          _fileRenameInformation,
        );
        if (ntStatus < 0) {
          throw WindowsNativeFailure(
            'rename-clean-directory',
            ntStatus,
            ntStatus: true,
          );
        }
      } finally {
        release(buffer.cast<Void>());
      }
    } finally {
      release(status.cast<Void>());
    }
  }

  Pointer<Void> _openRelative(
    Pointer<Void> parent,
    String leaf, {
    required int desiredAccess,
    required int shareAccess,
    required int disposition,
    required int options,
    required String operation,
  }) => withWideString(leaf, (wideLeaf) {
    final handleTarget = allocateBytes(sizeOf<IntPtr>()).cast<Pointer<Void>>();
    final unicode = allocateBytes(
      sizeOf<_WindowsUnicodeString>(),
    ).cast<_WindowsUnicodeString>();
    final attributes = allocateBytes(
      sizeOf<_WindowsObjectAttributes>(),
    ).cast<_WindowsObjectAttributes>();
    final status = allocateBytes(
      sizeOf<_WindowsIoStatusBlock>(),
    ).cast<_WindowsIoStatusBlock>();
    try {
      handleTarget.value = nullptr;
      unicode.ref
        ..length = leaf.codeUnits.length * 2
        ..maximumLength = leaf.codeUnits.length * 2
        ..buffer = wideLeaf;
      attributes.ref
        ..length = sizeOf<_WindowsObjectAttributes>()
        ..rootDirectory = parent
        ..objectName = unicode
        ..attributes = _objectCaseInsensitive
        ..securityDescriptor = nullptr
        ..securityQualityOfService = nullptr;
      final ntStatus = _ntCreateFile(
        handleTarget,
        desiredAccess,
        attributes,
        status,
        nullptr,
        _fileAttributeNormal,
        shareAccess,
        disposition,
        options,
        nullptr,
        0,
      );
      if (ntStatus < 0) {
        throw WindowsNativeFailure(operation, ntStatus, ntStatus: true);
      }
      return handleTarget.value;
    } finally {
      release(status.cast<Void>());
      release(attributes.cast<Void>());
      release(unicode.cast<Void>());
      release(handleTarget.cast<Void>());
    }
  });

  /// Writes at most [length] bytes and returns exact progress.
  @override
  int write(Pointer<Void> handle, Pointer<Void> source, int length) {
    final count = allocateBytes(sizeOf<Uint32>()).cast<Uint32>();
    try {
      if (_writeFile(handle, source, length, count, nullptr) == 0) {
        throw WindowsNativeFailure('write-object', _getLastError());
      }
      return count.value;
    } finally {
      release(count.cast<Void>());
    }
  }

  /// Reads at most [length] bytes and returns exact progress.
  @override
  int read(Pointer<Void> handle, Pointer<Void> target, int length) {
    final count = allocateBytes(sizeOf<Uint32>()).cast<Uint32>();
    try {
      if (_readFile(handle, target, length, count, nullptr) == 0) {
        throw WindowsNativeFailure('read-object', _getLastError());
      }
      return count.value;
    } finally {
      release(count.cast<Void>());
    }
  }

  /// Flushes one retained handle.
  @override
  void flush(Pointer<Void> handle) {
    if (_flushFileBuffers(handle) == 0) {
      throw WindowsNativeFailure('flush-object', _getLastError());
    }
  }

  /// Rewinds one retained handle.
  @override
  void rewind(Pointer<Void> handle) {
    if (_setFilePointer(handle, 0, nullptr, _moveBegin) == 0) {
      throw WindowsNativeFailure('rewind-object', _getLastError());
    }
  }

  /// Reads stable file ID, length, type, and reparse state from [handle].
  @override
  WindowsHandleIdentityData identity(Pointer<Void> handle) {
    final id = allocateBytes(24);
    final standard = allocateBytes(24);
    final tag = allocateBytes(8);
    try {
      _queryInformation(handle, _fileIdInfo, id, 24, 'identify-file-id');
      _queryInformation(
        handle,
        _fileStandardInfo,
        standard,
        24,
        'identify-file-type',
      );
      _queryInformation(
        handle,
        _fileAttributeTagInfo,
        tag,
        8,
        'identify-reparse-state',
      );
      final idBytes = id.asTypedList(24).buffer.asByteData();
      final standardBytes = standard.asTypedList(24).buffer.asByteData();
      final tagBytes = tag.asTypedList(8).buffer.asByteData();
      return WindowsHandleIdentityData(
        volumeSerial: idBytes.getUint64(0, Endian.host),
        fileId: id.asTypedList(24).sublist(8, 24),
        byteLength: standardBytes.getInt64(8, Endian.host),
        isDirectory: standard.asTypedList(24)[21] != 0,
        isReparsePoint:
            tagBytes.getUint32(0, Endian.host) & _reparsePointAttribute != 0,
      );
    } finally {
      release(tag.cast<Void>());
      release(standard.cast<Void>());
      release(id.cast<Void>());
    }
  }

  /// Fails unless [directory] belongs to an NTFS volume.
  @override
  void verifyNtfs(Pointer<Void> directory) {
    const capacity = 32;
    final fileSystemName = allocateBytes(capacity * 2).cast<Uint16>();
    try {
      final result = _getVolumeInformation(
        directory,
        nullptr,
        0,
        nullptr,
        nullptr,
        nullptr,
        fileSystemName,
        capacity,
      );
      if (result == 0) {
        throw WindowsNativeFailure('identify-filesystem', _getLastError());
      }
      if (_readWideString(fileSystemName, capacity).toUpperCase() != 'NTFS') {
        throw const WindowsNativeFailure('unsupported-filesystem', 0);
      }
    } finally {
      release(fileSystemName.cast<Void>());
    }
  }

  /// Closes one retained handle exactly once.
  @override
  void close(Pointer<Void> handle) {
    if (_closeHandle(handle) == 0) {
      throw WindowsNativeFailure('close-handle', _getLastError());
    }
  }

  /// Allocates zeroed process-heap bytes.
  @override
  Pointer<Uint8> allocateBytes(int length) {
    final pointer = _heapAllocate(_heap, _heapZeroMemory, length).cast<Uint8>();
    if (pointer.address == 0) {
      throw const WindowsNativeFailure('allocate-native-memory', 0);
    }
    return pointer;
  }

  /// Releases process-heap bytes from [allocateBytes].
  @override
  void release(Pointer<Void> pointer) {
    if (_heapFree(_heap, 0, pointer) == 0) {
      throw WindowsNativeFailure('release-native-memory', _getLastError());
    }
  }

  /// Calls [callback] with a temporary null-terminated UTF-16 string.
  T withWideString<T>(String value, T Function(Pointer<Uint16>) callback) {
    if (value.codeUnits.contains(0)) throw ArgumentError.value(value, 'value');
    final pointer = allocateBytes(
      (value.codeUnits.length + 1) * 2,
    ).cast<Uint16>();
    try {
      pointer.asTypedList(value.codeUnits.length + 1)
        ..setRange(0, value.codeUnits.length, value.codeUnits)
        ..[value.codeUnits.length] = 0;
      return callback(pointer);
    } finally {
      release(pointer.cast<Void>());
    }
  }

  void _queryInformation(
    Pointer<Void> handle,
    int informationClass,
    Pointer<Uint8> target,
    int length,
    String operation,
  ) {
    if (_getHandleInformation(
          handle,
          informationClass,
          target.cast<Void>(),
          length,
        ) ==
        0) {
      throw WindowsNativeFailure(operation, _getLastError());
    }
  }
}

bool _isInvalidHandle(Pointer<Void> handle) {
  final invalidAddress = sizeOf<IntPtr>() == 8
      ? 0xffffffffffffffff
      : 0xffffffff;
  return handle.address == invalidAddress;
}

String _readWideString(Pointer<Uint16> pointer, int capacity) {
  final values = pointer.asTypedList(capacity);
  final end = values.indexOf(0);
  return String.fromCharCodes(end < 0 ? values : values.sublist(0, end));
}
