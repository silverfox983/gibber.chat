import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/story_models.dart';
import 'spaces_service.dart';
import 'http_upload_service.dart';

class StoryService {
  static const String _storiesNode = 'urn:xmpp:stories';
  static const String _viewedStoriesKey = 'viewed_stories';
  static const Duration _storyExpireDuration = Duration(hours: 24);

  final SpacesService _spacesService;
  final xmpp.Connection _connection;
  final String accountJid;

  final Map<String, List<Story>> _storyCache = {};
  final Map<String, List<Story>> _myStoriesCache = {};
  bool _viewedLoaded = false;
  Set<String> _viewedIds = {};

  StoryService(this._spacesService, this._connection, this.accountJid);

  String get _accountDomain => accountJid.contains('@') ? accountJid.split('@')[1] : accountJid;

  Future<void> _ensureViewedLoaded() async {
    if (_viewedLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _viewedIds = prefs.getStringList(_viewedStoriesKey)?.toSet() ?? {};
    _viewedLoaded = true;
  }

  Future<void> _markViewed(String storyId) async {
    await _ensureViewedLoaded();
    if (_viewedIds.add(storyId)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_viewedStoriesKey, _viewedIds.toList());
    }
  }

  List<Story> _filterExpired(List<Story> stories) {
    final now = DateTime.now();
    return stories.where((s) => !now.isAfter(s.expiresAt)).toList();
  }

  Future<List<Story>> fetchMyStories() async {
    if (_myStoriesCache.containsKey(accountJid)) {
      return _filterExpired(_myStoriesCache[accountJid]!);
    }
    await _ensureViewedLoaded();
    final items = await _spacesService.fetchSpaceContent(_accountDomain, _storiesNode);
    final stories = items.map((item) => _parseStory(item, accountJid)).whereType<Story>().toList();
    for (final s in stories) {
      if (_viewedIds.contains(s.id)) {
        _myStoriesCache[accountJid] ??= [];
        _myStoriesCache[accountJid]!.add(s.copyWith(viewed: true));
      } else {
        _myStoriesCache[accountJid] ??= [];
        _myStoriesCache[accountJid]!.add(s);
      }
    }
    _myStoriesCache[accountJid] ??= stories;
    return _filterExpired(_myStoriesCache[accountJid]!);
  }

  Future<List<Story>> fetchContactStories(String contactJid) async {
    final domain = contactJid.contains('@') ? contactJid.split('@')[1] : contactJid;
    if (_storyCache.containsKey(contactJid)) {
      return _filterExpired(_storyCache[contactJid]!);
    }
    await _ensureViewedLoaded();
    try {
      final items = await _spacesService.fetchSpaceContent(domain, _storiesNode);
      final stories = items.map((item) => _parseStory(item, contactJid)).whereType<Story>().toList();
      final withViewed = stories.map((s) {
        return _viewedIds.contains(s.id) ? s.copyWith(viewed: true) : s;
      }).toList();
      _storyCache[contactJid] = withViewed;
      return _filterExpired(withViewed);
    } catch (e) {
      debugPrint('Failed to fetch stories for $contactJid: $e');
      return [];
    }
  }

  Future<List<Story>> fetchContactsStories(List<String> contactJids) async {
    final allStories = <String, Story>{};
    for (final jid in contactJids) {
      final stories = await fetchContactStories(jid);
      for (final s in stories) {
        if (!allStories.containsKey(s.id)) {
          allStories[s.id] = s;
        }
      }
    }
    return allStories.values.toList();
  }

  Future<Story?> publishStory(File image, {String? caption}) async {
    final uploadService = HttpUploadService(_connection);
    final fileName = image.path.split(RegExp(r'[/\\]')).last;
    final size = await image.length();
    final ext = fileName.split('.').last.toLowerCase();
    var contentType = 'image/$ext';
    if (ext == 'jpg') {
      contentType = 'image/jpeg';
    }

    final slot = await uploadService.requestUploadSlot(fileName, size, contentType: contentType);
    if (slot == null) {
      debugPrint('StoryService: Failed to get upload slot');
      return null;
    }

    bool upSuccess;
    if (kIsWeb) {
      final bytes = await image.readAsBytes();
      upSuccess = await uploadService.uploadBytes(slot['put']!, bytes, contentType);
    } else {
      upSuccess = await uploadService.uploadFile(slot['put']!, image, contentType);
    }

    if (!upSuccess) {
      debugPrint('StoryService: Upload failed');
      return null;
    }

    final getUrl = slot['get']!;
    final now = DateTime.now();
    final storyId = 'story_${now.millisecondsSinceEpoch}';
    final postedAt = now;
    final expiresAt = now.add(_storyExpireDuration);

    final entry = xmpp.XmppElement();
    entry.name = 'entry';
    entry.addAttribute(xmpp.XmppAttribute('xmlns', 'http://www.w3.org/2005/Atom'));

    final idEl = xmpp.XmppElement()..name = 'id'..textValue = storyId;
    entry.addChild(idEl);

    final published = xmpp.XmppElement()..name = 'published'..textValue = postedAt.toUtc().toIso8601String();
    entry.addChild(published);

    final link = xmpp.XmppElement();
    link.name = 'link';
    link.addAttribute(xmpp.XmppAttribute('rel', 'enclosure'));
    link.addAttribute(xmpp.XmppAttribute('url', getUrl));
    link.addAttribute(xmpp.XmppAttribute('type', contentType));
    entry.addChild(link);

    if (caption != null && caption.isNotEmpty) {
      final summary = xmpp.XmppElement()..name = 'summary'..textValue = caption;
      entry.addChild(summary);
    }

    final success = await _spacesService.publishItem(_accountDomain, _storiesNode, entry, itemId: storyId, autoCreateNode: true);
    if (!success) {
      debugPrint('StoryService: Failed to publish story item');
      return null;
    }

    final story = Story(
      id: storyId,
      authorJid: accountJid,
      mediaUrl: getUrl,
      caption: caption,
      postedAt: postedAt,
      expiresAt: expiresAt,
      mediaType: contentType,
    );

    _myStoriesCache[accountJid] ??= [];
    _myStoriesCache[accountJid]!.insert(0, story);
    return story;
  }

  Future<void> markViewed(String storyId) async {
    await _markViewed(storyId);
    for (final cache in [_myStoriesCache, _storyCache]) {
      for (final key in cache.keys) {
        final idx = cache[key]!.indexWhere((s) => s.id == storyId);
        if (idx >= 0) {
          cache[key]![idx] = cache[key]![idx].copyWith(viewed: true);
        }
      }
    }
  }

  Future<bool> deleteStory(String storyId) async {
    final domain = accountJid.contains('@') ? accountJid.split('@')[1] : accountJid;
    final ok = await _spacesService.retractItem(domain, _storiesNode, storyId);
    if (ok) {
      for (final cache in [_myStoriesCache, _storyCache]) {
        for (final key in cache.keys) {
          cache[key]!.removeWhere((s) => s.id == storyId);
        }
      }
    }
    return ok;
  }

  Story? _parseStory(dynamic item, String authorJid) {
    try {
      final id = item.id ?? '';
      if (id.isEmpty) return null;

      DateTime? postedAt;
      final publishedEl = item.getChild('published');
      if (publishedEl != null) {
        postedAt = DateTime.tryParse(publishedEl.textValue ?? '');
      }
      postedAt ??= DateTime.now();

      final expiresAt = postedAt.add(_storyExpireDuration);
      if (DateTime.now().isAfter(expiresAt)) {
        return null;
      }

      String? mediaUrl;
      String? mediaType;
      final enclosure = item.getChild('link', xmlns: null);
      if (enclosure != null) {
        mediaUrl = enclosure.getAttribute('url')?.value;
        mediaType = enclosure.getAttribute('type')?.value;
      }

      if (mediaUrl == null) return null;

      String? caption;
      final summary = item.getChild('summary');
      if (summary != null) {
        caption = summary.textValue;
      }

      return Story(
        id: id,
        authorJid: authorJid,
        mediaUrl: mediaUrl,
        caption: caption,
        postedAt: postedAt,
        expiresAt: expiresAt,
        mediaType: mediaType,
      );
    } catch (e) {
      debugPrint('Failed to parse story item: $e');
      return null;
    }
  }

  void invalidateCache() {
    _storyCache.clear();
    _myStoriesCache.clear();
  }
}
