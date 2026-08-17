import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';
import '../models/user_profile.dart';
import 'auth_service_deps.dart';
import 'avatar_cache_service.dart';

class XmppVCardService {
  final AuthServiceVCardDeps _d;

  XmppVCardService(this._d);

  Future<void> updateMyVCard({
    required String accountId,
    String? fullName,
    String? nickName,
    String? description,
    String? email,
    String? phone,
    String? url,
    String? organization,
    String? title,
    String? role,
    String? birthday,
  }) async {
    final conn = _d.xmppConnections[accountId];
    if (conn == null) return;

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));

    if (fullName != null) {
      final fn = xmpp.XmppElement();
      fn.name = 'FN';
      fn.textValue = fullName;
      vcard.addChild(fn);
    }

    if (nickName != null) {
      final nick = xmpp.XmppElement();
      nick.name = 'NICKNAME';
      nick.textValue = nickName;
      vcard.addChild(nick);
    }

    if (description != null) {
      final desc = xmpp.XmppElement();
      desc.name = 'DESC';
      desc.textValue = description;
      vcard.addChild(desc);
    }

    if (email != null) {
      final el = xmpp.XmppElement()..name = 'EMAIL';
      el.addChild(xmpp.XmppElement()..name = 'USERID'..textValue = email);
      vcard.addChild(el);
    }
    if (phone != null) {
      final el = xmpp.XmppElement()..name = 'TEL';
      el.addChild(xmpp.XmppElement()..name = 'NUMBER'..textValue = phone);
      vcard.addChild(el);
    }
    if (url != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'URL'..textValue = url);
    }
    if (organization != null) {
      final el = xmpp.XmppElement()..name = 'ORG';
      el.addChild(xmpp.XmppElement()..name = 'ORGNAME'..textValue = organization);
      vcard.addChild(el);
    }
    if (title != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'TITLE'..textValue = title);
    }
    if (role != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'ROLE'..textValue = role);
    }
    if (birthday != null) {
      vcard.addChild(xmpp.XmppElement()..name = 'BDAY'..textValue = birthday);
    }

    iq.addChild(vcard);
    conn.writeStanza(iq);

    if (_d.currentProfile != null) {
      _d.currentProfile!.displayName = fullName ?? _d.currentProfile!.displayName;
      _d.currentProfile!.nickName = nickName ?? _d.currentProfile!.nickName;
      _d.currentProfile!.bio = description ?? _d.currentProfile!.bio;
      _d.currentProfile!.email = email ?? _d.currentProfile!.email;
      _d.currentProfile!.phone = phone ?? _d.currentProfile!.phone;
      _d.currentProfile!.url = url ?? _d.currentProfile!.url;
      _d.currentProfile!.organization = organization ?? _d.currentProfile!.organization;
      _d.currentProfile!.title = title ?? _d.currentProfile!.title;
      _d.currentProfile!.role = role ?? _d.currentProfile!.role;
      _d.currentProfile!.birthday = birthday ?? _d.currentProfile!.birthday;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'current_profile',
        json.encode(_d.currentProfile!.toJson()),
      );
      _d.notifyListeners();
    }
  }

  Future<void> fetchMyVCard({String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    if (id != null) {
      await _d.fetchVCard(id, _d.xmppJids[id]!.split('/').first);
    }
  }

  Future<void> setMyAvatar(String accountId, File image) async {
    final conn = _d.xmppConnections[accountId];
    if (conn == null) return;

    final bytes = await image.readAsBytes();
    final photoBase64 = base64Encode(bytes);

    final iq = xmpp.IqStanza(
      DateTime.now().millisecondsSinceEpoch.toString(),
      xmpp.IqStanzaType.SET,
    );
    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));

    final photo = xmpp.XmppElement();
    photo.name = 'PHOTO';
    final type = xmpp.XmppElement();
    type.name = 'TYPE';
    type.textValue = 'image/jpeg';
    photo.addChild(type);
    final binval = xmpp.XmppElement();
    binval.name = 'BINVAL';
    binval.textValue = photoBase64;
    photo.addChild(binval);
    vcard.addChild(photo);

    iq.addChild(vcard);
    conn.writeStanza(iq);

    final myJid = _d.xmppJids[accountId];
    if (myJid != null) {
      await AvatarCacheService().saveAvatar(myJid.split('/').first, bytes);
      _d.notifyListeners();

      await _d.updateMyStatus(_d.myStatus, message: _d.myStatusMessage);
    }
  }

  Future<void> fetchVCard(String accountId, String jid) async {
    if (jid.isEmpty) return;

    String cleanJid = jid.toLowerCase();

    if (cleanJid.endsWith('.vom')) {
      cleanJid = cleanJid.replaceFirst('.vom', '.com');
    }

    final cacheKey = '$accountId:$cleanJid';

    if (_d.vCardUnsupportedJids.contains(cleanJid)) return;

    final now = DateTime.now();
    if (_d.vCardLastFetch.containsKey(cacheKey)) {
      if (now.difference(_d.vCardLastFetch[cacheKey]!) <
          const Duration(hours: 1)) {
        return;
      }
    }

    if (_d.pendingVCardFetches.contains(cacheKey)) return;
    _d.pendingVCardFetches.add(cacheKey);

    final conn = _d.xmppConnections[accountId];
    if (conn == null) {
      _d.pendingVCardFetches.remove(cacheKey);
      return;
    }

    _d.vCardLastFetch[cacheKey] = now;

    await Future.delayed(Duration(milliseconds: 50 + (jid.hashCode % 450)));

    final iq = xmpp.IqStanza(
      'vcard_${DateTime.now().millisecondsSinceEpoch}_${jid.hashCode}',
      xmpp.IqStanzaType.GET,
    );

    final myBareJid = _d.xmppJids[accountId]?.split('/').first.toLowerCase();
    if (cleanJid != myBareJid) {
      iq.toJid = xmpp.Jid.fromFullJid(jid);
    }

    final vcard = xmpp.XmppElement();
    vcard.name = 'vCard';
    vcard.addAttribute(xmpp.XmppAttribute('xmlns', 'vcard-temp'));
    iq.addChild(vcard);
    conn.writeStanza(iq);

    Timer(const Duration(seconds: 15), () {
      _d.pendingVCardFetches.remove(cacheKey);
    });
  }
}