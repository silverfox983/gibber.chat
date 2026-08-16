class File {
  final String path;
  File(this.path);
  Future<int> length() async => 0;
  Stream<List<int>> openRead() => const Stream.empty();
  Future<bool> exists() async => false;
}