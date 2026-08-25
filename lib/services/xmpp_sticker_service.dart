import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class StickerPack {
  final String id;
  final String name;
  final String? description;
  final String? iconUrl;
  final List<StickerItem> stickers;

  StickerPack({
    required this.id,
    required this.name,
    this.description,
    this.iconUrl,
    this.stickers = const [],
  });
}

class StickerItem {
  final String id;
  final String url;
  final String? mimeType;
  final String? hash;
  final int? width;
  final int? height;
  final List<String> keywords;

  StickerItem({
    required this.id,
    required this.url,
    this.mimeType,
    this.hash,
    this.width,
    this.height,
    this.keywords = const [],
  });
}

class XmppStickerService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  XmppStickerService(this._connections, this._xmppJids);

  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  Future<List<StickerPack>> fetchStickerPacks(String accountId) async {
    final conn = _connections[accountId];
    if (conn == null) return [];

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return [];

    final iq = xmpp.IqStanza(
      'sticker_packs_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = xmpp.XmppElement();
    items.name = 'items';
    items.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:stickers:0'));
    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final res = await _sendIq(iq, conn);
      final pubsubRes = res.getChild('pubsub');
      final itemsEl = pubsubRes?.getChild('items');
      if (itemsEl == null) return [];

      final packs = <StickerPack>[];
      for (var item in itemsEl.children.where((e) => e.name == 'item')) {
        final pack = _parseStickerPack(item);
        if (pack != null) packs.add(pack);
      }
      return packs;
    } catch (e) {
      debugPrint('Sticker: Failed to fetch sticker packs: $e');
      return [];
    }
  }

  Future<bool> publishStickerPack(String accountId, StickerPack pack) async {
    final conn = _connections[accountId];
    if (conn == null) return false;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return false;

    final iq = xmpp.IqStanza(
      'sticker_publish_${xmpp.AbstractStanza.getRandomId()}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:stickers:0'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', pack.id));

    final packEl = xmpp.XmppElement();
    packEl.name = 'pack';
    packEl.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:stickers:0'));

    final nameEl = xmpp.XmppElement()..name = 'name'..textValue = pack.name;
    packEl.addChild(nameEl);

    if (pack.description != null) {
      final descEl = xmpp.XmppElement()..name = 'description'..textValue = pack.description;
      packEl.addChild(descEl);
    }

    for (var sticker in pack.stickers) {
      final stickerEl = xmpp.XmppElement();
      stickerEl.name = 'sticker';
      stickerEl.addAttribute(xmpp.XmppAttribute('id', sticker.id));

      if (sticker.mimeType != null) {
        stickerEl.addAttribute(xmpp.XmppAttribute('type', sticker.mimeType));
      }
      if (sticker.hash != null) {
        final hashEl = xmpp.XmppElement();
        hashEl.name = 'hash';
        hashEl.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hashes:2'));
        hashEl.addAttribute(xmpp.XmppAttribute('algo', 'sha-256'));
        hashEl.textValue = sticker.hash;
        stickerEl.addChild(hashEl);
      }

      if (sticker.width != null && sticker.height != null) {
        final dimensions = xmpp.XmppElement();
        dimensions.name = 'dimensions';
        dimensions.addAttribute(xmpp.XmppAttribute('width', sticker.width.toString()));
        dimensions.addAttribute(xmpp.XmppAttribute('height', sticker.height.toString()));
        stickerEl.addChild(dimensions);
      }

      for (var kw in sticker.keywords) {
        final keyword = xmpp.XmppElement();
        keyword.name = 'keyword';
        keyword.textValue = kw;
        stickerEl.addChild(keyword);
      }

      packEl.addChild(stickerEl);
    }

    item.addChild(packEl);
    publish.addChild(item);
    pubsub.addChild(publish);

    final publishOptions = xmpp.XmppElement();
    publishOptions.name = 'publish-options';
    final xData = xmpp.XmppElement();
    xData.name = 'x';
    xData.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    xData.addAttribute(xmpp.XmppAttribute('type', 'submit'));
    xData.addChild(_makeField('FORM_TYPE', 'hidden', 'http://jabber.org/protocol/pubsub#publish-options'));
    xData.addChild(_makeField('pubsub#access_model', null, 'open'));
    publishOptions.addChild(xData);
    pubsub.addChild(publishOptions);

    iq.addChild(pubsub);
    conn.writeStanza(iq);
    debugPrint('Sticker: Published sticker pack ${pack.id}');
    return true;
  }

  Future<void> sendStickerMessage({
    required String accountId,
    required String targetJid,
    required StickerItem sticker,
    bool isGroup = false,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      isGroup ? xmpp.MessageStanzaType.GROUPCHAT : xmpp.MessageStanzaType.CHAT,
    );
    final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
    msg.toJid = xmpp.Jid.fromFullJid(finalTarget);
    msg.body = sticker.url;

    // XEP-0231: Bits of Binary
    if (sticker.hash != null && sticker.mimeType != null) {
      final data = xmpp.XmppElement();
      data.name = 'data';
      data.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:bob'));
      data.addAttribute(xmpp.XmppAttribute('cid', 'sha256+$sticker.hash@bob.xmpp.org'));
      data.addAttribute(xmpp.XmppAttribute('type', sticker.mimeType));
      msg.addChild(data);
    }

    // XEP-0367: Message Attaching for sticker reference
    final attach = xmpp.XmppElement();
    attach.name = 'attach';
    attach.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:message-attaching:1'));
    msg.addChild(attach);

    conn.writeStanza(msg);
    debugPrint('Sticker: Sent sticker message to $targetJid');
  }

  StickerPack? _parseStickerPack(xmpp.XmppElement item) {
    final id = item.getAttribute('id')?.value;
    if (id == null) return null;

    for (var child in item.children) {
      if (child.name == 'pack' && child.getAttribute('xmlns')?.value == 'urn:xmpp:stickers:0') {
        String? name;
        String? description;
        final stickers = <StickerItem>[];

        for (var packChild in child.children) {
          if (packChild.name == 'name') {
            name = packChild.textValue;
          } else if (packChild.name == 'description') {
            description = packChild.textValue;
          } else if (packChild.name == 'sticker') {
            final stickerId = packChild.getAttribute('id')?.value ?? '';
            final mimeType = packChild.getAttribute('type')?.value;
            String? hash;
            int? width;
            int? height;
            final keywords = <String>[];

            final hashEl = packChild.getChild('hash');
            if (hashEl != null) hash = hashEl.textValue;

            final dimsEl = packChild.getChild('dimensions');
            if (dimsEl != null) {
              width = int.tryParse(dimsEl.getAttribute('width')?.value ?? '');
              height = int.tryParse(dimsEl.getAttribute('height')?.value ?? '');
            }

            for (var kwEl in packChild.children.where((e) => e.name == 'keyword')) {
              if (kwEl.textValue != null) keywords.add(kwEl.textValue!);
            }

            if (stickerId.isNotEmpty) {
              stickers.add(StickerItem(
                id: stickerId,
                url: '',
                mimeType: mimeType,
                hash: hash,
                width: width,
                height: height,
                keywords: keywords,
              ));
            }
          }
        }

        return StickerPack(
          id: id,
          name: name ?? id,
          description: description,
          stickers: stickers,
        );
      }
    }
    return null;
  }

  xmpp.XmppElement _makeField(String varAttr, String? type, String value) {
    final field = xmpp.XmppElement()..name = 'field';
    field.addAttribute(xmpp.XmppAttribute('var', varAttr));
    if (type != null) field.addAttribute(xmpp.XmppAttribute('type', type));
    final val = xmpp.XmppElement()..name = 'value'..textValue = value;
    field.addChild(val);
    return field;
  }

  Future<xmpp.IqStanza> _sendIq(xmpp.IqStanza originalIq, xmpp.Connection conn,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final id = 'sticker_${xmpp.AbstractStanza.getRandomId()}';
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
}