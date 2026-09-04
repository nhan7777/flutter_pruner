/// Least-privilege directory authority requested from `NtCreateFile`.
enum WindowsCleanDirectoryOpenMode {
  /// Observe identity and type without mutation authority.
  inspect,

  /// Open an existing directory with child-mutation and flush authority.
  openWritable,

  /// Open an existing directory with source-rename authority.
  renameSource,

  /// Open an existing directory or create it with writable authority.
  ensureWritable,

  /// Create a new directory exclusively with writable authority.
  createExclusive,
}
