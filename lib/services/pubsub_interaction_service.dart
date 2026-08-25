import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/space_models.dart';

class PubSubInteractionService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  PubSubInteractionService(this._connections, this._xmppJids);

  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  final StreamController<PubSubLikeEvent> _likeEventController =
      StreamController<PubSubLikeEvent>.broadcast();
  Stream<PubSubLikeEvent> get likeEvents => _likeEventController.stream;

  final StreamController<PubSubCommentEvent> _commentEventController =
      StreamController<PubSubCommentEvent>.broadcast();
  Stream<PubSubCommentEvent> get commentEvents => _commentEventController.stream;

  Future<String> publishComment({
    required String accountId,
    required String nodeId,
    required String serviceJid,
    required String inReplyTo,
    required String content,
    String? contentType,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return '';

    final itemId = 'comment_${DateTime.now().millisecondsSinceEpoch}_${xmpp.AbstractStanza.getRandomId()}';

    final iq = xmpp.IqStanza(
      'pubsub_comment_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(serviceJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', nodeId));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', itemId));

    final entry = xmpp.XmppElement();
    entry.name = 'entry';
    entry.addAttribute(xmpp.XmppAttribute('xmlns', 'http://www.w3.org/2005/Atom'));

    final title = xmpp.XmppElement();
    title.name = 'title';
    title.textValue = content;
    entry.addChild(title);

    final contentEl = xmpp.XmppElement();
    contentEl.name = 'content';
    contentEl.addAttribute(xmpp.XmppAttribute('type', contentType ?? 'text'));
    contentEl.textValue = content;
    entry.addChild(contentEl);

    final replyTo = xmpp.XmppElement();
    replyTo.name = 'thr:in-reply-to';
    replyTo.addAttribute(xmpp.XmppAttribute('xmlns', 'http://purl.org/syndication/thread/1.0'));
    replyTo.addAttribute(xmpp.XmppAttribute('ref', inReplyTo));
    replyTo.addAttribute(xmpp.XmppAttribute('href', inReplyTo));
    entry.addChild(replyTo);

    final authorJid = _xmppJids[accountId]?.split('/').first ?? '';
    final authorEl = xmpp.XmppElement();
    authorEl.name = 'author';
    final authorUri = xmpp.XmppElement();
    authorUri.name = 'uri';
    authorUri.textValue = 'xmpp:$authorJid';
    authorEl.addChild(authorUri);
    entry.addChild(authorEl);

    final published = xmpp.XmppElement();
    published.name = 'published';
    published.textValue = _formatXmppDateTime(DateTime.now().toUtc());
    entry.addChild(published);

    final updated = xmpp.XmppElement();
    updated.name = 'updated';
    updated.textValue = _formatXmppDateTime(DateTime.now().toUtc());
    entry.addChild(updated);

    item.addChild(entry);
    publish.addChild(item);
    pubsub.addChild(publish);

    final publishOptions = xmpp.XmppElement();
    publishOptions.name = 'publish-options';
    final xData = xmpp.XmppElement();
    xData.name = 'x';
    xData.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    xData.addAttribute(xmpp.XmppAttribute('type', 'submit'));
    final fieldType = _makeField('FORM_TYPE', 'hidden', 'http://jabber.org/protocol/pubsub#publish-options');
    xData.addChild(fieldType);
    final fieldAccess = _makeField('pubsub#access_model', null, 'open');
    xData.addChild(fieldAccess);
    publishOptions.addChild(xData);
    pubsub.addChild(publishOptions);

    iq.addChild(pubsub);
    conn.writeStanza(iq);

    _commentEventController.add(PubSubCommentEvent(
      itemId: itemId,
      nodeId: nodeId,
      serviceJid: serviceJid,
      inReplyTo: inReplyTo,
      content: content,
      authorJid: authorJid,
      timestamp: DateTime.now(),
    ));

    return itemId;
  }

  Future<bool> toggleLike({
    required String accountId,
    required String itemId,
    required String nodeId,
    required String serviceJid,
    required bool isCurrentlyLiked,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return false;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return false;

    if (isCurrentlyLiked) {
      final likeNodeId = '${nodeId}_reactions';
      final likeItemId = 'like_${bareJid.hashCode.abs()}';

      final iq = xmpp.IqStanza(
        'pubsub_unlike_${xmpp.AbstractStanza.getRandomId()}',
        xmpp.IqStanzaType.SET,
      );
      iq.toJid = xmpp.Jid.fromFullJid(serviceJid);

      final pubsub = xmpp.XmppElement();
      pubsub.name = 'pubsub';
      pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

      final retract = xmpp.XmppElement();
      retract.name = 'retract';
      retract.addAttribute(xmpp.XmppAttribute('node', likeNodeId));
      retract.addAttribute(xmpp.XmppAttribute('notify', 'true'));

      final item = xmpp.XmppElement();
      item.name = 'item';
      item.addAttribute(xmpp.XmppAttribute('id', likeItemId));
      retract.addChild(item);
      pubsub.addChild(retract);
      iq.addChild(pubsub);
      conn.writeStanza(iq);

      _likeEventController.add(PubSubLikeEvent(
        itemId: itemId,
        nodeId: nodeId,
        serviceJid: serviceJid,
        liked: false,
        userJid: bareJid,
      ));
      return true;
    } else {
      final likeNodeId = '${nodeId}_reactions';
      final likeItemId = 'like_${bareJid.hashCode.abs()}';

      final iq = xmpp.IqStanza(
        'pubsub_like_${xmpp.AbstractStanza.getRandomId()}',
        xmpp.IqStanzaType.SET,
      );
      iq.toJid = xmpp.Jid.fromFullJid(serviceJid);

      final pubsub = xmpp.XmppElement();
      pubsub.name = 'pubsub';
      pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

      final publish = xmpp.XmppElement();
      publish.name = 'publish';
      publish.addAttribute(xmpp.XmppAttribute('node', likeNodeId));

      final item = xmpp.XmppElement();
      item.name = 'item';
      item.addAttribute(xmpp.XmppAttribute('id', likeItemId));

      final reaction = xmpp.XmppElement();
      reaction.name = 'reaction';
      reaction.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:reactions:0'));
      reaction.textValue = '\u2764\uFE0F';
      item.addChild(reaction);

      final authorEl = xmpp.XmppElement();
      authorEl.name = 'author';
      final authorUri = xmpp.XmppElement();
      authorUri.name = 'uri';
      authorUri.textValue = 'xmpp:$bareJid';
      authorEl.addChild(authorUri);
      item.addChild(authorEl);

      publish.addChild(item);
      pubsub.addChild(publish);
      iq.addChild(pubsub);
      conn.writeStanza(iq);

      _likeEventController.add(PubSubLikeEvent(
        itemId: itemId,
        nodeId: nodeId,
        serviceJid: serviceJid,
        liked: true,
        userJid: bareJid,
      ));
      return true;
    }
  }

  Future<List<SpaceItem>> fetchComments({
    required String accountId,
    required String commentNode,
    required String serviceJid,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return [];

    final iq = xmpp.IqStanza(
      'pubsub_comments_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(serviceJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = xmpp.XmppElement();
    items.name = 'items';
    items.addAttribute(xmpp.XmppAttribute('node', commentNode));

    final rsm = xmpp.XmppElement();
    rsm.name = 'set';
    rsm.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/rsm'));
    final max = xmpp.XmppElement()..name = 'max'..textValue = '50';
    rsm.addChild(max);
    items.addChild(rsm);

    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final res = await _sendIq(iq, conn);
      final pubsubRes = res.getChild('pubsub');
      final itemsEl = pubsubRes?.getChild('items');
      if (itemsEl == null) return [];

      final comments = <SpaceItem>[];
      for (var itemEl in itemsEl.children.where((e) => e.name == 'item')) {
        final id = itemEl.getAttribute('id')?.value ?? '';
        for (var child in itemEl.children) {
          if (child.name == 'entry' &&
              child.getAttribute('xmlns')?.value == 'http://www.w3.org/2005/Atom') {
            final title = child.getChild('title')?.textValue ?? '';
            final content = child.getChild('content')?.textValue ?? title;
            final authorUri = child.getChild('author')?.getChild('uri')?.textValue ?? '';
            final authorJid = authorUri.replaceFirst('xmpp:', '');
            final published = child.getChild('published')?.textValue;
            final replyTo = child.children
                .where((e) => e.name == 'thr:in-reply-to' || e.name == 'in-reply-to')
                .firstOrNull
                ?.getAttribute('ref')
                ?.value;

            comments.add(SpaceItem(
              id: id,
              type: 'comment',
              name: title,
              description: content,
              author: authorJid.isNotEmpty ? authorJid.split('@').first : null,
              publishedDate: published != null ? DateTime.tryParse(published) : null,
              replyToId: replyTo,
              rawContent: content,
              contentType: child.getChild('content')?.getAttribute('type')?.value,
            ));
          }
        }
      }
      comments.sort((a, b) =>
          (b.publishedDate ?? DateTime.now()).compareTo(a.publishedDate ?? DateTime.now()));
      return comments;
    } catch (e) {
      debugPrint('PubSub: Comment fetch failed: $e');
      return [];
    }
  }

  Future<Map<String, int>> fetchReactionCounts({
    required String accountId,
    required String itemId,
    required String serviceJid,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return {};

    final reactionNode = '${itemId}_reactions';

    final iq = xmpp.IqStanza(
      'pubsub_reactions_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(serviceJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = xmpp.XmppElement();
    items.name = 'items';
    items.addAttribute(xmpp.XmppAttribute('node', reactionNode));
    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final res = await _sendIq(iq, conn);
      final pubsubRes = res.getChild('pubsub');
      final itemsEl = pubsubRes?.getChild('items');
      if (itemsEl == null) return {};

      final reactions = <String, int>{};
      for (var itemEl in itemsEl.children.where((e) => e.name == 'item')) {
        final reaction = itemEl.getChild('reaction');
        final emoji = reaction?.textValue ?? '\u2764\uFE0F';
        reactions[emoji] = (reactions[emoji] ?? 0) + 1;
      }
      return reactions;
    } catch (e) {
      debugPrint('PubSub: Reaction fetch failed: $e');
      return {};
    }
  }

  Future<bool> sharePostToChat({
    required String accountId,
    required String targetJid,
    required String postId,
    required String postUrl,
    String? postTitle,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return false;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.CHAT,
    );
    msg.toJid = xmpp.Jid.fromFullJid(targetJid);
    msg.body = postTitle != null ? '$postTitle\n$postUrl' : postUrl;

    final reference = xmpp.XmppElement();
    reference.name = 'reference';
    reference.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:reference:0'));
    reference.addAttribute(xmpp.XmppAttribute('begin', '0'));
    reference.addAttribute(xmpp.XmppAttribute('end', postUrl.length.toString()));
    reference.addAttribute(xmpp.XmppAttribute('type', 'mention'));
    reference.addAttribute(xmpp.XmppAttribute('uri', postUrl));
    msg.addChild(reference);

    final oob = xmpp.XmppElement();
    oob.name = 'x';
    oob.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:oob'));
    final urlEl = xmpp.XmppElement()..name = 'url'..textValue = postUrl;
    oob.addChild(urlEl);
    if (postTitle != null) {
      final descEl = xmpp.XmppElement()..name = 'desc'..textValue = postTitle;
      oob.addChild(descEl);
    }
    msg.addChild(oob);

    conn.writeStanza(msg);
    return true;
  }

  Future<bool> sharePostToRoom({
    required String accountId,
    required String roomJid,
    required String postId,
    required String postUrl,
    String? postTitle,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return false;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.MessageStanzaType.GROUPCHAT,
    );
    msg.toJid = xmpp.Jid.fromFullJid(roomJid.split('/').first);
    msg.body = postTitle != null ? '$postTitle\n$postUrl' : postUrl;

    final oob = xmpp.XmppElement();
    oob.name = 'x';
    oob.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:oob'));
    final urlEl = xmpp.XmppElement()..name = 'url'..textValue = postUrl;
    oob.addChild(urlEl);
    if (postTitle != null) {
      final descEl = xmpp.XmppElement()..name = 'desc'..textValue = postTitle;
      oob.addChild(descEl);
    }
    msg.addChild(oob);

    conn.writeStanza(msg);
    return true;
  }

  xmpp.XmppElement _makeField(String varAttr, String? type, String value) {
    final field = xmpp.XmppElement()..name = 'field';
    field.addAttribute(xmpp.XmppAttribute('var', varAttr));
    if (type != null) field.addAttribute(xmpp.XmppAttribute('type', type));
    final val = xmpp.XmppElement()..name = 'value'..textValue = value;
    field.addChild(val);
    return field;
  }

  String _formatXmppDateTime(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}T'
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}Z';
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza originalIq, xmpp.Connection conn,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final id = 'pubsub_interact_${xmpp.AbstractStanza.getRandomId()}';
    final iq = xmpp.IqStanza(id, originalIq.type);
    iq.toJid = originalIq.toJid;
    for (var child in originalIq.children) {
      iq.addChild(child);
    }

    final completer = Completer<xmpp.IqStanza>();
    _pendingIqs[id] = completer;
    conn.writeStanza(iq);

    try {
      return await completer.future.timeout(timeout);
    } catch (e) {
      _pendingIqs.remove(id);
      rethrow;
    }
  }

  void handleIqResponse(xmpp.IqStanza iq) {
    final id = iq.id;
    if (id != null && _pendingIqs.containsKey(id)) {
      _pendingIqs[id]!.complete(iq);
      _pendingIqs.remove(id);
    }
  }

  void dispose() {
    _likeEventController.close();
    _commentEventController.close();
    for (final completer in _pendingIqs.values) {
      if (!completer.isCompleted) completer.completeError('Service disposed');
    }
    _pendingIqs.clear();
  }
}

class PubSubLikeEvent {
  final String itemId;
  final String nodeId;
  final String serviceJid;
  final bool liked;
  final String userJid;

  PubSubLikeEvent({
    required this.itemId,
    required this.nodeId,
    required this.serviceJid,
    required this.liked,
    required this.userJid,
  });
}

class PubSubCommentEvent {
  final String itemId;
  final String nodeId;
  final String serviceJid;
  final String inReplyTo;
  final String content;
  final String authorJid;
  final DateTime timestamp;

  PubSubCommentEvent({
    required this.itemId,
    required this.nodeId,
    required this.serviceJid,
    required this.inReplyTo,
    required this.content,
    required this.authorJid,
    required this.timestamp,
  });
}