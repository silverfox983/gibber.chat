import 'dart:convert';

import 'popular_room.dart';

/// Parses the plain-text rendering of netsplit.de/channels/popular.php.
///
/// Entries look like:
/// ```
/// #linux Libera.Chat
/// Chat Room - 2350 users -
/// current topic: Welcome to #linux! ...
/// category: Linux -
/// network: Libera.Chat
/// ```
List<PopularRoom> parseNetsplitPopular(String raw) {
  final lines = raw.split('\n').map((l) => l.trim()).toList();
  final rooms = <PopularRoom>[];

  String? channel;
  String? network;
  int users = 0;
  String? topic;
  String? category;
  bool hasStats = false;

  void flush() {
    if (channel != null && network != null && hasStats) {
      rooms.add(PopularRoom(
        channel: channel!,
        network: network!,
        users: users,
        category: category,
        topic: topic,
      ));
    }
    channel = null;
    network = null;
    users = 0;
    topic = null;
    category = null;
    hasStats = false;
  }

  final statsRe = RegExp(r'^Chat Room\s*-\s*(\d[\d.,]*)\s*users');
  final topicRe = RegExp('^current topic:\\s*(.*)\$');
  final categoryRe = RegExp('^category:\\s*(.*?)\\s*(-|\$)');
  final entryRe = RegExp(r'^(#{1,2}\S+)\s+(.+)$');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // "\#channel Network" begins a new entry.
    final head = entryRe.firstMatch(line);
    if (head != null) {
      flush();
      channel = head.group(1);
      network = head.group(2);
      continue;
    }

    final stats = statsRe.firstMatch(line);
    if (stats != null) {
      users = int.tryParse((stats.group(1) ?? '0').replaceAll(RegExp(r'[.,]'), '')) ?? 0;
      hasStats = true;
      continue;
    }

    final topicMatch = topicRe.firstMatch(line);
    if (topicMatch != null) {
      // The topic may wrap across following "category: ..." / "network: ..." lines.
      final buffer = StringBuffer(topicMatch.group(1) ?? '');
      var j = i + 1;
      while (j < lines.length &&
          lines[j].isNotEmpty &&
          !lines[j].startsWith('network:') &&
          !lines[j].startsWith('category:') &&
          statsRe.hasMatch(lines[j] == '' ? 'x' : lines[j]) == false &&
          RegExp(r'^#{1,2}\S+\s+').hasMatch(lines[j]) == false) {
        _joinTopic(buffer, lines[j]);
        j++;
      }
      final parsedTopic = buffer.toString().trim();
      if (parsedTopic.isNotEmpty) topic = parsedTopic;
      continue;
    }

    final cat = categoryRe.firstMatch(line);
    if (cat != null) {
      category = cat.group(1)?.trim();
      continue;
    }

    if (line.startsWith('network:')) {
      final n = line.substring('network:'.length).trim();
      if (n.isNotEmpty) network = n;
      continue;
    }

    if (line == 'Chat Room' && !hasStats) continue;
  }
  flush();

  // Deduplicate identical (channel, network) pairs - keep the first.
  final seen = <String>{};
  return rooms.where((r) => seen.add('${r.network}|${r.channel}')).toList();
}

void _joinTopic(StringBuffer buffer, String line) {
  if (buffer.isNotEmpty) buffer.write(' ');
  buffer.write(line);
}

/// Parses the bundled JSON snapshot asset.
List<PopularRoom> parseNetsplitSnapshot(String jsonStr) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(jsonStr);
  } catch (_) {
    return const <PopularRoom>[];
  }
  final rooms = (decoded is Map && decoded['rooms'] is List)
      ? decoded['rooms'] as List
      : <dynamic>[];
  return rooms
      .whereType<Map>()
      .map((m) => PopularRoom.fromJson(Map<String, dynamic>.from(m)))
      .where((r) => r.channel.isNotEmpty && r.network.isNotEmpty)
      .toList();
}