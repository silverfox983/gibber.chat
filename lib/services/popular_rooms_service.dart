import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'popular_room.dart';
import 'popular_rooms_parser.dart';

/// Loads popular IRC rooms for the landing page.
///
/// Always serves the bundled snapshot; additionally attempts a live refresh
/// from netsplit.de (its server does not send CORS headers, so a browser
/// fetch usually fails and the snapshot stands unchanged).
class PopularRoomsService {
  static const String netsplitPopularUrl =
      'https://netsplit.de/channels/popular.php';

  List<PopularRoom>? _cached;
  bool _isLive = false;

  /// True when the last successful load came from a live netsplit.de fetch.
  bool get isLiveRefresh => _isLive;

  Future<List<PopularRoom>> load({bool forceRefresh = false}) async {
    if (!forceRefresh && _cached != null) return _cached!;
    _isLive = false;

    List<PopularRoom> rooms = await _loadBundled();

    try {
      final response = await http
          .get(Uri.parse(netsplitPopularUrl))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final parsed = parseNetsplitPopular(response.body);
        // Live data must pass a sanity bar so a layout change cannot wipe the
        // section; otherwise the bundled snapshot keeps serving.
        if (parsed.length >= 10 && parsed.every((r) => r.users > 0 && r.network.isNotEmpty)) {
          rooms = parsed;
          _isLive = true;
        }
      }
    } catch (_) {
      // CORS/network failure - the bundled snapshot stands.
    }

    _cached = rooms;
    return rooms;
  }

  Future<List<PopularRoom>> _loadBundled() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/netsplit_popular.json');
      return parseNetsplitSnapshot(jsonStr);
    } catch (_) {
      return const <PopularRoom>[];
    }
  }
}