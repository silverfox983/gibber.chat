import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class XmppPepService {
  final Map<String, xmpp.Connection> _connections;
  final Map<String, String> _xmppJids;

  XmppPepService(this._connections, this._xmppJids);

  final Map<String, Completer<xmpp.IqStanza>> _pendingIqs = {};

  Future<void> publishAvatarPep(
    String accountId,
    Uint8List imageBytes, {
    String mimeType = 'image/png',
    int width = 0,
    int height = 0,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return;

    final sha1Hash = _sha1Hex(imageBytes);
    final base64Data = base64Encode(imageBytes);

    final dataIq = xmpp.IqStanza(
      'avatar_data_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    dataIq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsubData = xmpp.XmppElement();
    pubsubData.name = 'pubsub';
    pubsubData.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publishData = xmpp.XmppElement();
    publishData.name = 'publish';
    publishData.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:avatar:data'));

    final itemData = xmpp.XmppElement();
    itemData.name = 'item';
    itemData.addAttribute(xmpp.XmppAttribute('id', sha1Hash));

    final dataEl = xmpp.XmppElement();
    dataEl.name = 'data';
    dataEl.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:avatar:data'));
    dataEl.textValue = base64Data;
    itemData.addChild(dataEl);
    publishData.addChild(itemData);
    pubsubData.addChild(publishData);
    dataIq.addChild(pubsubData);

    conn.writeStanza(dataIq);

    final metadataIq = xmpp.IqStanza(
      'avatar_meta_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    metadataIq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsubMeta = xmpp.XmppElement();
    pubsubMeta.name = 'pubsub';
    pubsubMeta.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publishMeta = xmpp.XmppElement();
    publishMeta.name = 'publish';
    publishMeta.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:avatar:metadata'));

    final itemMeta = xmpp.XmppElement();
    itemMeta.name = 'item';
    itemMeta.addAttribute(xmpp.XmppAttribute('id', sha1Hash));

    final metadata = xmpp.XmppElement();
    metadata.name = 'metadata';
    metadata.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:avatar:metadata'));

    final info = xmpp.XmppElement();
    info.name = 'info';
    info.addAttribute(xmpp.XmppAttribute('bytes', imageBytes.length.toString()));
    info.addAttribute(xmpp.XmppAttribute('id', sha1Hash));
    info.addAttribute(xmpp.XmppAttribute('type', mimeType));
    if (width > 0) info.addAttribute(xmpp.XmppAttribute('width', width.toString()));
    if (height > 0) info.addAttribute(xmpp.XmppAttribute('height', height.toString()));
    metadata.addChild(info);
    itemMeta.addChild(metadata);
    publishMeta.addChild(itemMeta);
    pubsubMeta.addChild(publishMeta);
    metadataIq.addChild(pubsubMeta);

    conn.writeStanza(metadataIq);
    debugPrint('PEP: Published avatar data+metadata (hash: $sha1Hash)');
  }

  Future<Uint8List?> fetchAvatarPep(String accountId, String bareJid) async {
    final conn = _connections[accountId];
    if (conn == null) return null;

    final metadataIq = xmpp.IqStanza(
      'avatar_meta_fetch_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    metadataIq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsubMeta = xmpp.XmppElement();
    pubsubMeta.name = 'pubsub';
    pubsubMeta.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final itemsMeta = xmpp.XmppElement();
    itemsMeta.name = 'items';
    itemsMeta.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:avatar:metadata'));
    pubsubMeta.addChild(itemsMeta);
    metadataIq.addChild(pubsubMeta);

    try {
      final metaRes = await _sendIq(metadataIq, conn);
      final metaPubsub = metaRes.getChild('pubsub');
      if (metaPubsub == null) return null;

      final metaItems = metaPubsub.getChild('items');
      final metaItem = metaItems?.children.firstWhere(
        (e) => e.name == 'item',
        orElse: () => xmpp.XmppElement(),
      );
      if (metaItem?.name != 'item') return null;

      final metadata = metaItem?.getChild('metadata');
      final info = metadata?.children.firstWhere(
        (e) => e.name == 'info',
        orElse: () => xmpp.XmppElement(),
      );
      final itemId = info?.getAttribute('id')?.value;
      if (itemId == null) return null;

      final dataIq = xmpp.IqStanza(
        'avatar_data_fetch_${DateTime.now().microsecondsSinceEpoch}',
        xmpp.IqStanzaType.GET,
      );
      dataIq.toJid = xmpp.Jid.fromFullJid(bareJid);

      final pubsubData = xmpp.XmppElement();
      pubsubData.name = 'pubsub';
      pubsubData.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
      final itemsData = xmpp.XmppElement();
      itemsData.name = 'items';
      itemsData.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:avatar:data'));
      final itemData = xmpp.XmppElement();
      itemData.name = 'item';
      itemData.addAttribute(xmpp.XmppAttribute('id', itemId));
      itemsData.addChild(itemData);
      pubsubData.addChild(itemsData);
      dataIq.addChild(pubsubData);

      final dataRes = await _sendIq(dataIq, conn);
      final dataPubsub = dataRes.getChild('pubsub');
      final dataItem = dataPubsub?.getChild('items')?.children.firstWhere(
        (e) => e.name == 'item',
        orElse: () => xmpp.XmppElement(),
      );
      final dataEl = dataItem?.getChild('data');
      final base64Str = dataEl?.textValue;
      if (base64Str == null) return null;

      return base64Decode(base64Str.replaceAll(RegExp(r'\s'), ''));
    } catch (e) {
      debugPrint('PEP: Avatar fetch failed for $bareJid: $e');
      return null;
    }
  }

  Future<void> publishNicknamePep(String accountId, String nickname) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return;

    final iq = xmpp.IqStanza(
      'nick_publish_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', 'http://jabber.org/protocol/nick'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    final nick = xmpp.XmppElement();
    nick.name = 'nick';
    nick.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/nick'));
    nick.textValue = nickname;
    item.addChild(nick);
    publish.addChild(item);
    pubsub.addChild(publish);
    iq.addChild(pubsub);

    conn.writeStanza(iq);
    debugPrint('PEP: Published nickname: $nickname');
  }

  Future<String?> fetchNicknamePep(String accountId, String bareJid) async {
    final conn = _connections[accountId];
    if (conn == null) return null;

    final iq = xmpp.IqStanza(
      'nick_fetch_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = xmpp.XmppElement();
    items.name = 'items';
    items.addAttribute(xmpp.XmppAttribute('node', 'http://jabber.org/protocol/nick'));
    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final res = await _sendIq(iq, conn);
      final pubsubRes = res.getChild('pubsub');
      final item = pubsubRes?.getChild('items')?.children.firstWhere(
        (e) => e.name == 'item',
        orElse: () => xmpp.XmppElement(),
      );
      final nick = item?.getChild('nick');
      return nick?.textValue;
    } catch (e) {
      debugPrint('PEP: Nickname fetch failed for $bareJid: $e');
      return null;
    }
  }

  Future<void> publishLastInteraction(String accountId) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return;

    final iq = xmpp.IqStanza(
      'last_interaction_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:last-interaction:0'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', 'current'));

    final timeEl = xmpp.XmppElement();
    timeEl.name = 'time';
    timeEl.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:last-interaction:0'));
    timeEl.addAttribute(xmpp.XmppAttribute('stamp', _formatXmppDateTime(DateTime.now())));
    item.addChild(timeEl);
    publish.addChild(item);
    pubsub.addChild(publish);
    iq.addChild(pubsub);

    conn.writeStanza(iq);
  }

  Future<void> publishBanner(
    String accountId,
    Uint8List imageBytes, {
    String mimeType = 'image/png',
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return;

    final sha1Hash = _sha1Hex(imageBytes);

    final iq = xmpp.IqStanza(
      'banner_pub_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));

    final publish = xmpp.XmppElement();
    publish.name = 'publish';
    publish.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:banner:0'));

    final item = xmpp.XmppElement();
    item.name = 'item';
    item.addAttribute(xmpp.XmppAttribute('id', sha1Hash));

    final bannerEl = xmpp.XmppElement();
    bannerEl.name = 'url';
    bannerEl.textValue = '';
    item.addChild(bannerEl);
    publish.addChild(item);

    final publishOptions = xmpp.XmppElement();
    publishOptions.name = 'publish-options';
    final xForm = xmpp.XmppElement();
    xForm.name = 'x';
    xForm.addAttribute(xmpp.XmppAttribute('xmlns', 'jabber:x:data'));
    xForm.addAttribute(xmpp.XmppAttribute('type', 'submit'));
    final formType = xmpp.XmppElement()..name = 'field';
    formType.addAttribute(xmpp.XmppAttribute('var', 'FORM_TYPE'));
    formType.addAttribute(xmpp.XmppAttribute('type', 'hidden'));
    final formTypeVal = xmpp.XmppElement()..name = 'value'..textValue = 'http://jabber.org/protocol/pubsub#node_config';
    formType.addChild(formTypeVal);
    xForm.addChild(formType);
    final accessModel = xmpp.XmppElement()..name = 'field';
    accessModel.addAttribute(xmpp.XmppAttribute('var', 'pubsub#access_model'));
    final accessVal = xmpp.XmppElement()..name = 'value'..textValue = 'open';
    accessModel.addChild(accessVal);
    xForm.addChild(accessModel);
    publishOptions.addChild(xForm);

    pubsub.addChild(publish);
    pubsub.addChild(publishOptions);
    iq.addChild(pubsub);

    conn.writeStanza(iq);
    debugPrint('PEP: Published banner (hash: $sha1Hash)');
  }

  Future<String?> fetchBanner(String accountId, String bareJid) async {
    final conn = _connections[accountId];
    if (conn == null) return null;

    final iq = xmpp.IqStanza(
      'banner_fetch_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final pubsub = xmpp.XmppElement();
    pubsub.name = 'pubsub';
    pubsub.addAttribute(xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/pubsub'));
    final items = xmpp.XmppElement();
    items.name = 'items';
    items.addAttribute(xmpp.XmppAttribute('node', 'urn:xmpp:banner:0'));
    pubsub.addChild(items);
    iq.addChild(pubsub);

    try {
      final res = await _sendIq(iq, conn);
      final pubsubRes = res.getChild('pubsub');
      final item = pubsubRes?.getChild('items')?.children.firstWhere(
        (e) => e.name == 'item',
        orElse: () => xmpp.XmppElement(),
      );
      final urlEl = item?.getChild('url');
      return urlEl?.textValue;
    } catch (e) {
      debugPrint('PEP: Banner fetch failed for $bareJid: $e');
      return null;
    }
  }

  Future<void> publishVCard4(
    String accountId, {
    String? fn,
    String? nickname,
    String? note,
    String? email,
    String? tel,
    String? url,
    String? orgName,
    String? title,
    String? role,
    String? bday,
    String? pronouns,
  }) async {
    final conn = _connections[accountId];
    if (conn == null) return;

    final bareJid = _xmppJids[accountId]?.split('/').first ?? '';
    if (bareJid.isEmpty) return;

    final iq = xmpp.IqStanza(
      'vcard4_set_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.SET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final vcard = xmpp.XmppElement();
    vcard.name = 'vcard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:vcard-4.0'));

    if (fn != null) {
      final fnEl = xmpp.XmppElement()..name = 'fn';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = fn;
      fnEl.addChild(text);
      vcard.addChild(fnEl);
    }

    if (nickname != null) {
      final nickEl = xmpp.XmppElement()..name = 'nickname';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = nickname;
      nickEl.addChild(text);
      vcard.addChild(nickEl);
    }

    if (note != null) {
      final noteEl = xmpp.XmppElement()..name = 'note';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = note;
      noteEl.addChild(text);
      vcard.addChild(noteEl);
    }

    if (email != null) {
      final emailEl = xmpp.XmppElement()..name = 'email';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = email;
      emailEl.addChild(text);
      vcard.addChild(emailEl);
    }

    if (tel != null) {
      final telEl = xmpp.XmppElement()..name = 'tel';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = tel;
      telEl.addChild(text);
      vcard.addChild(telEl);
    }

    if (url != null) {
      final urlEl = xmpp.XmppElement()..name = 'url';
      final uri = xmpp.XmppElement()..name = 'uri';
      uri.textValue = url;
      urlEl.addChild(uri);
      vcard.addChild(urlEl);
    }

    if (orgName != null) {
      final orgEl = xmpp.XmppElement()..name = 'org';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = orgName;
      orgEl.addChild(text);
      vcard.addChild(orgEl);
    }

    if (title != null) {
      final titleEl = xmpp.XmppElement()..name = 'title';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = title;
      titleEl.addChild(text);
      vcard.addChild(titleEl);
    }

    if (role != null) {
      final roleEl = xmpp.XmppElement()..name = 'role';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = role;
      roleEl.addChild(text);
      vcard.addChild(roleEl);
    }

    if (bday != null) {
      final bdayEl = xmpp.XmppElement()..name = 'bday';
      final date = xmpp.XmppElement()..name = 'date';
      date.textValue = bday;
      bdayEl.addChild(date);
      vcard.addChild(bdayEl);
    }

    if (pronouns != null) {
      final pronounsEl = xmpp.XmppElement()..name = 'pronouns';
      final text = xmpp.XmppElement()..name = 'text';
      text.textValue = pronouns;
      pronounsEl.addChild(text);
      vcard.addChild(pronounsEl);
    }

    iq.addChild(vcard);
    conn.writeStanza(iq);
    debugPrint('vCard4: Published vCard4 for $bareJid');
  }

  Future<Map<String, String>?> fetchVCard4(String accountId, String bareJid) async {
    final conn = _connections[accountId];
    if (conn == null) return null;

    final iq = xmpp.IqStanza(
      'vcard4_get_${DateTime.now().microsecondsSinceEpoch}',
      xmpp.IqStanzaType.GET,
    );
    iq.toJid = xmpp.Jid.fromFullJid(bareJid);

    final vcard = xmpp.XmppElement();
    vcard.name = 'vcard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:ietf:params:xml:ns:vcard-4.0'));
    iq.addChild(vcard);

    try {
      final res = await _sendIq(iq, conn);
      final vcardRes = res.getChild('vcard');
      if (vcardRes == null) return null;

      final result = <String, String>{};

      for (final child in vcardRes.children.whereType<xmpp.XmppElement>()) {
        final name = child.name;
        switch (name) {
          case 'fn':
            result['fn'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'nickname':
            result['nickname'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'note':
            result['note'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'email':
            result['email'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'tel':
            result['tel'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'url':
            result['url'] = child.getChild('uri')?.textValue ?? '';
            break;
          case 'org':
            result['org'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'title':
            result['title'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'role':
            result['role'] = child.getChild('text')?.textValue ?? '';
            break;
          case 'bday':
            result['bday'] = child.getChild('date')?.textValue ?? '';
            break;
          case 'pronouns':
            result['pronouns'] = child.getChild('text')?.textValue ?? '';
            break;
        }
      }
      return result;
    } catch (e) {
      debugPrint('vCard4: Fetch failed for $bareJid: $e');
      return null;
    }
  }

  String _sha1Hex(Uint8List bytes) {
    int hash = 0;
    for (var i = 0; i < bytes.length; i++) {
      hash = ((hash << 5) - hash) + bytes[i];
      hash = hash & 0xFFFFFFFF;
    }
    return hash.abs().toRadixString(16).padLeft(8, '0');
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
    final id = 'pep_${xmpp.AbstractStanza.getRandomId()}';
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