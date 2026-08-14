class RateLimiter {
  final int maxRequests;
  final Duration window;
  final Map<String, List<DateTime>> _buckets = {};

  RateLimiter({required this.maxRequests, required this.window});

  bool allow(String key) {
    final now = DateTime.now();
    final cutoff = now.subtract(window);
    _buckets.putIfAbsent(key, () => []);
    final bucket = _buckets[key]!;

    bucket.removeWhere((ts) => ts.isBefore(cutoff));

    if (bucket.length < maxRequests) {
      bucket.add(now);
      return true;
    }
    return false;
  }

  void clear(String key) {
    _buckets.remove(key);
  }
}