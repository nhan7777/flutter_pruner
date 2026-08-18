class ForeignContainer {
  T get<T>() => throw UnsupportedError('fixture');

  Iterable<T> getAll<T>() => const [];
}

class ForeignCallable {
  T call<T>() => throw UnsupportedError('fixture');
}
