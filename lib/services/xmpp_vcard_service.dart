import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, Uint8List;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'auth_service_deps.dart';
import 'avatar_cache_service.dart';

class XmppVCardService {
  final AuthServiceVCardDeps _d;

  XmppVCardService(this._d);

  final Map<String, Completer<bool>> _pendingVCardSets = {};

  Future<void> fetchMyVCard({String? accountId}) async {
    final id = accountId ?? _d.activeAccountId;
    if (id != null) {
      await _d.fetchVCard(id, _d.xmppJids[id]!.split('/').first);
    }
  }

  Future<bool> updateMyVCard({
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
    if (conn == null) return false;

    final iqId = 'vcard_set_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<bool>();
    _pendingVCardSets[iqId] = completer;

    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
    final vcard = _buildVCardElement(
      fullName: fullName,
      nickName: nickName,
      description: description,
      email: email,
      phone: phone,
      url: url,
      organization: organization,
      title: title,
      role: role,
      birthday: birthday,
    );
    iq.addChild(vcard);

    _setupSetTimeout(iqId, completer);
    conn.writeStanza(iq);

    final success = await completer.future;
    if (success) {
      _updateLocalProfile(
        fullName: fullName,
        nickName: nickName,
        description: description,
        email: email,
        phone: phone,
        url: url,
        organization: organization,
        title: title,
        role: role,
        birthday: birthday,
      );
    }
    return success;
  }

  Future<bool> setMyAvatarBytes(String accountId, Uint8List bytes) async {
    return _setMyAvatarImpl(accountId, bytes);
  }

  Future<bool> setMyAvatar(String accountId, Uint8List bytes) async {
    return _setMyAvatarImpl(accountId, bytes);
  }

  Future<bool> _setMyAvatarImpl(String accountId, Uint8List bytes) async {
    final conn = _d.xmppConnections[accountId];
    if (conn == null) return false;

    final iqId = 'vcard_avatar_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<bool>();
    _pendingVCardSets[iqId] = completer;

    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.SET);
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
    binval.textValue = base64Encode(bytes);
    photo.addChild(binval);
    vcard.addChild(photo);

    iq.addChild(vcard);

    _setupSetTimeout(iqId, completer);
    conn.writeStanza(iq);

    final success = await completer.future;
    if (success) {
      final myJid = _d.xmppJids[accountId];
      if (myJid != null) {
        await AvatarCacheService().saveAvatar(myJid.split('/').first, bytes);
        _d.notifyListeners();
        await _d.updateMyStatus(_d.myStatus, message: _d.myStatusMessage);
      }
    }
    return success;
  }

  void handleVCardSetResult(String iqId, bool success, String? errorText) {
    final completer = _pendingVCardSets.remove(iqId);
    if (completer != null && !completer.isCompleted) {
      if (success) {
        completer.complete(true);
      } else {
        debugPrint('XmppVCardService: vCard SET $iqId failed: $errorText');
        completer.complete(false);
      }
    }
  }

  void _setupSetTimeout(String iqId, Completer<bool> completer) {
    Future.delayed(const Duration(seconds: 10), () {
      final c = _pendingVCardSets.remove(iqId);
      if (c != null && !c.isCompleted) {
        debugPrint('XmppVCardService: vCard SET $iqId timed out');
        c.complete(false);
      }
    });
  }

  xmpp.XmppElement _buildVCardElement({
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
  }) {
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

    return vcard;
  }

  void _updateLocalProfile({
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

  Future<void> fetchVCard(String accountId, String jid) async {
    if (jid.isEmpty) return;

    String cleanJid = jid.toLowerCase();

    // Cheogram-specific: .vom -> .com for vCard lookups
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

    // Remove pending on vCard receipt in stanza handler (not on timer).
    // The pendingVCardFetches tracking will be cleared when vCard response arrives.
  }
}
