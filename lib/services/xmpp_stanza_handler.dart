import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';
import '../models/picked_file.dart';
import 'auth_service_deps.dart';
import 'jingle_signaling_service.dart';
import 'xmpp_omemo_service.dart';

class XmppStanzaHandler {
  final AuthServiceStanzaDeps _d;

  XmppStanzaHandler(this._d);

  MessageType _classifyMessage(String text, xmpp.XmppElement? parent) {
    final oobX = parent?.getChild('x');
    if (oobX != null && oobX.getAttribute('xmlns')?.value == 'jabber:x:oob') {
      final urlEl = oobX.getChild('url');
      if (urlEl != null && urlEl.textValue != null) {
        return PickedFile.classifyFromUrl(urlEl.textValue!);
      }
    }

    final trimmed = text.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      if (PickedFile.isImageUrl(trimmed)) return MessageType.image;
      if (PickedFile.isFileUrl(trimmed)) return MessageType.file;
    }

    return MessageType.text;
  }

  String? _extractOobUrl(xmpp.XmppElement? parent) {
    final oobX = parent?.getChild('x');
    if (oobX != null && oobX.getAttribute('xmlns')?.value == 'jabber:x:oob') {
      return oobX.getChild('url')?.textValue;
    }
    return null;
  }

  String _extractFileName(String url) => PickedFile.fileNameFromUrl(url);

  Future<void> handleMessageStanza(
    xmpp.MessageStanza stanza,
    String accountId,
    xmpp.Connection conn,
  ) async {
    if (stanza.type == xmpp.MessageStanzaType.ERROR) {
      final errorEl = stanza.getChild('error');
      String errorText = 'Message failed';
      if (errorEl != null) {
        final textEl = errorEl.getChild('text');
        errorText = textEl?.textValue ?? errorEl.children.map((c) => c.name).join(', ');
      }
      final failedMsgId = stanza.id ?? '';
      debugPrint('XMPP: Received error stanza for message $failedMsgId: $errorText');
      _d.jingleEventController.add(
        JingleEvent(
          action: JingleAction.messageError,
          sessionId: 'error',
          fromJid: stanza.fromJid?.fullJid ?? '',
          accountId: accountId,
          reason: failedMsgId,
          sdp: errorText,
        ),
      );
      return;
    }

    final eventEl = stanza.getChild('event');
    if (eventEl != null &&
        eventEl.getAttribute('xmlns')?.value ==
            'http://jabber.org/protocol/pubsub#event') {
      final items = eventEl.getChild('items');
      if (items != null &&
          items.getAttribute('node')?.value ==
              'urn:xmpp:omemo:0:devices') {
        final bareJid =
            stanza.fromJid?.fullJid?.split('/').first.toLowerCase() ?? '';
        if (bareJid.isNotEmpty) {
          for (var item in items.children.where((c) => c.name == 'item')) {
            final list = item.getChild('list');
            if (list != null &&
                list.getAttribute('xmlns')?.value == XmppOmemoService.nsOmemo) {
              for (var device in list.children.where((c) => c.name == 'device')) {
                final idStr = device.getAttribute('id')?.value;
                if (idStr != null) {
                  final devId = int.tryParse(idStr);
                  if (devId != null) {
                    _d.omemoService.buildSession(bareJid, devId).then((_) {
                      _d.notifyListeners();
                    });
                  }
                }
              }
              debugPrint('OMEMO: Received live device list update from $bareJid');
            }
          }
        }
      }
    }

    _d.jingleServices[accountId]?.handleIncomingMessage(stanza);

    final request = stanza.getChild('request');
    if (_d.sendReadReceipts &&
        request != null &&
        request.getAttribute('xmlns')?.value == 'urn:xmpp:receipts') {
      final receipt = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        stanza.type,
      );
      receipt.toJid = stanza.fromJid;
      final receivedEl = xmpp.XmppElement();
      receivedEl.name = 'received';
      receivedEl.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:receipts'),
      );
      receivedEl.addAttribute(
        xmpp.XmppAttribute('id', stanza.id ?? ''),
      );
      receipt.addChild(receivedEl);
      conn.writeStanza(receipt);
    }

    final chatState = stanza.children.firstWhere(
      (c) =>
          c.getAttribute('xmlns')?.value ==
          'http://jabber.org/protocol/chatstates',
      orElse: () => xmpp.XmppElement(),
    );
    if (chatState.name != null) {
      _d.jingleEventController.add(
        JingleEvent(
          action: JingleAction.transportInfo,
          sessionId: 'typing',
          fromJid: stanza.fromJid?.fullJid ?? '',
          reason: chatState.name,
          accountId: accountId,
        ),
      );
    }

    final received = stanza.getChild('received');
    if (received != null &&
        received.getAttribute('xmlns')?.value == 'urn:xmpp:receipts') {
      _d.jingleEventController.add(
        JingleEvent(
          action: JingleAction.transportInfo,
          sessionId: 'receipt',
          fromJid: stanza.fromJid?.fullJid ?? '',
          reason: received.getAttribute('id')?.value,
          accountId: accountId,
        ),
      );
    }

    final displayed = stanza.getChild('displayed');
    if (displayed != null &&
        displayed.getAttribute('xmlns')?.value == 'urn:xmpp:chat-markers:0') {
      _d.jingleEventController.add(
        JingleEvent(
          action: JingleAction.transportInfo,
          sessionId: 'marker',
          fromJid: stanza.fromJid?.fullJid ?? '',
          reason: displayed.getAttribute('id')?.value,
          accountId: accountId,
        ),
      );
    }

    final reactions = stanza.getChild('reactions');
    if (reactions != null &&
        reactions.getAttribute('xmlns')?.value == 'urn:xmpp:reactions:0') {
      final targetId = reactions.getAttribute('id')?.value;
      if (targetId != null) {
        for (var reactionEl in reactions.children) {
          if (reactionEl.name == 'reaction') {
            final emoji = reactionEl.textValue;
            if (emoji != null && emoji.isNotEmpty) {
              _d.jingleEventController.add(
                JingleEvent(
                  action: JingleAction.transportInfo,
                  sessionId: 'reaction',
                  fromJid: stanza.fromJid?.fullJid ?? '',
                  reason: targetId,
                  sdp: emoji,
                  accountId: accountId,
                ),
              );
            }
          }
        }
      }
    }

    for (var child in stanza.children) {
      final ns = child.getAttribute('xmlns')?.value;

      if (child.name == 'x' && ns == 'jabber:x:conference') {
        final roomJid = child.getAttribute('jid')?.value;
        if (roomJid != null) {
          debugPrint('MUC: Received Direct Invite to $roomJid');
          _d.roomService.emitGroupInvite({
            'accountId': accountId,
            'roomJid': roomJid,
            'fromJid': stanza.fromJid?.fullJid ?? '',
            'reason': child.getAttribute('reason')?.value,
            'password': child.getAttribute('password')?.value,
          });

          _d.messageStreamController.add(
            ChatMessage(
              id: 'invite_${DateTime.now().millisecondsSinceEpoch}',
              text: 'INVITE: $roomJid',
              timestamp: DateTime.now(),
              isSent: false,
              senderId: stanza.fromJid?.fullJid,
              senderName: stanza.fromJid?.local,
              type: MessageType.system,
            ),
          );
        }
      }

      if (child.name == 'x' &&
          ns == 'http://jabber.org/protocol/muc#user') {
        final invite = child.getChild('invite');
        if (invite != null) {
          final fromJid =
              invite.getAttribute('from')?.value ??
              stanza.fromJid?.fullJid ??
              '';
          debugPrint('MUC: Received Mediated Invite from $fromJid');
          _d.roomService.emitGroupInvite({
            'accountId': accountId,
            'roomJid': stanza.fromJid?.fullJid ?? '',
            'fromJid': fromJid,
            'reason': invite.getChild('reason')?.textValue,
          });
        }
      }
    }

    if (stanza.type == xmpp.MessageStanzaType.GROUPCHAT) {
      final body = stanza.getChild('body')?.textValue;
      final fromJid = stanza.fromJid?.fullJid ?? '';
      final roomJid = stanza.fromJid?.local != null
          ? '${stanza.fromJid!.local}@${stanza.fromJid!.domain}'
          : stanza.fromJid?.domain ?? '';
      final nick = stanza.fromJid?.resource ?? 'Unknown';

      String? finalBody = body;
      final encrypted = stanza.getChild('encrypted');
      if (encrypted != null) {
        final delay = stanza.getChild('delay');
        final decrypted = await _d.omemoService.decryptMessage(
          encrypted,
          fromBareJid: roomJid.toLowerCase(),
          isHistorical: delay != null,
        );
        if (decrypted != null) {
          finalBody = decrypted;
        } else {
          finalBody = '🔒 [Decryption Failed - Rebuilding Session...]';
          _d.omemoService.fetchDeviceList(roomJid.toLowerCase()).then((devices) {
            for (var devId in devices) {
              _d.omemoService.buildSession(roomJid.toLowerCase(), devId);
            }
          });
        }
      }

      final subject = stanza.getChild('subject')?.textValue;
      if (subject != null) {
        _d.messageStreamController.add(
          ChatMessage(
            id: 'subject_${roomJid}_${DateTime.now().microsecondsSinceEpoch}',
            text: 'Topic changed to: $subject',
            timestamp: DateTime.now(),
            isSent: false,
            senderId: roomJid,
            senderName: nick,
            conversationId: roomJid.toLowerCase(),
            accountId: accountId,
            protocol: 'XMPP',
            type: MessageType.system,
            isGroup: true,
          ),
        );
      }

      bool isMe = false;
      final myNick = _d.roomService.getNickname(accountId, roomJid.toLowerCase());
      if (myNick != null) {
        isMe = (nick == myNick);
      } else {
        final myBareJid =
            _d.xmppJids[accountId]?.split('/').first.toLowerCase() ?? '';
        final myUsername = myBareJid.split('@').first;
        if (nick == myUsername ||
            nick == _d.currentProfile?.displayName ||
            nick == _d.currentProfile?.nickName) {
          isMe = true;
        }
      }

      if (finalBody != null) {
        final msgType = _classifyMessage(finalBody, stanza);
        final oobUrl = _extractOobUrl(stanza);
        final fileName = oobUrl != null ? _extractFileName(oobUrl) : null;

        _d.messageStreamController.add(
          ChatMessage(
            id: stanza.id ?? 'xmpp_${DateTime.now().microsecondsSinceEpoch}',
            text: oobUrl ?? finalBody,
            timestamp: DateTime.now(),
            isSent: isMe,
            senderId: fromJid,
            senderName: nick,
            accountId: accountId,
            protocol: 'XMPP',
            conversationId: roomJid.toLowerCase(),
            type: msgType,
            isGroup: true,
            fileName: fileName,
          ),
        );
      }
    } else if (stanza.type == xmpp.MessageStanzaType.CHAT) {
      final body = stanza.body;
      final fromJid = stanza.fromJid?.fullJid ?? '';
      final bareJid = fromJid.split('/').first.toLowerCase();

      String? finalBody = body;
      final encrypted = stanza.getChild('encrypted');
      if (encrypted != null) {
        final delay = stanza.getChild('delay');
        final decrypted = await _d.omemoService.decryptMessage(
          encrypted,
          fromBareJid: bareJid,
          isHistorical: delay != null,
        );
        if (decrypted != null) {
          finalBody = decrypted;
        } else {
          finalBody = '🔒 [Decryption Failed - Rebuilding Session...]';
          _d.refreshOmemoDevices(bareJid);
        }
      }

      if (finalBody != null) {
        final replacesId = stanza
            .getChild('replace')
            ?.getAttribute('id')
            ?.value;
        final isRetraction =
            stanza.getChild('apply-to')?.getChild('retract') != null;

        if (bareJid.isNotEmpty) {
          finalBody = _d.otrService.processIncomingMessage(bareJid, finalBody);
        }

        if (finalBody == null) return;

        final geoEl = stanza.getChild('geo');
        final isLocation = geoEl != null && geoEl.getAttribute('xmlns')?.value == 'http://jabber.org/protocol/geoloc';
        double? lat;
        double? lon;
        String? locLabel;
        if (isLocation) {
          lat = double.tryParse(geoEl.getChild('lat')?.textValue ?? '');
          lon = double.tryParse(geoEl.getChild('lon')?.textValue ?? '');
          locLabel = geoEl.getChild('label')?.textValue;
        }

        _d.messageStreamController.add(
          ChatMessage(
            id: stanza.id ?? 'xmpp_${DateTime.now().microsecondsSinceEpoch}',
            text: isRetraction ? '🚫 Message retracted' : (_extractOobUrl(stanza) ?? finalBody),
            timestamp: DateTime.now(),
            isSent: false,
            type: isRetraction
                ? MessageType.system
                : (isLocation ? MessageType.location : _classifyMessage(finalBody, stanza)),
            senderId: bareJid,
            senderName: bareJid.split('@').first,
            conversationId: bareJid,
            accountId: accountId,
            protocol: 'XMPP',
            replacesId: replacesId,
            encryptionType: encrypted != null ? 'omemo' : null,
            latitude: lat,
            longitude: lon,
            locationLabel: locLabel,
            fileName: _extractOobUrl(stanza) != null ? _extractFileName(_extractOobUrl(stanza)!) : null,
          ),
        );
      }
    }

    final mamResult = stanza.getChild('result');
    if (mamResult != null &&
        (mamResult.name == 'result' ||
            mamResult
                    .getAttribute('xmlns')
                    ?.value
                    ?.startsWith('urn:xmpp:mam:') ==
                true)) {
      try {
        final forwarded = mamResult.getChild('forwarded');
        if (forwarded != null) {
          final delay = forwarded.getChild('delay');
          final innerMessage = forwarded.getChild('message');
          if (innerMessage != null) {
            String? body = innerMessage.getChild('body')?.textValue;
            final fromJidStr = innerMessage.getAttribute('from')?.value;

            final encrypted = innerMessage.getChild('encrypted');
            if (encrypted != null && fromJidStr != null) {
              final bareJid = fromJidStr.split('/').first.toLowerCase();
              final decrypted = await _d.omemoService.decryptMessage(
                encrypted,
                fromBareJid: bareJid,
                isHistorical: true,
              );
              if (decrypted != null) {
                body = decrypted;
              } else {
                body = '🔒 [Decryption Failed - Rebuilding Session...]';
                _d.refreshOmemoDevices(bareJid);
              }
            }

            if (body != null) {
              final stamp = delay?.getAttribute('stamp')?.value;
              final timestamp = stamp != null
                  ? DateTime.parse(stamp)
                  : DateTime.now();

              final myJid = _d.xmppJids[accountId];
              final isSent = fromJidStr != null &&
                  myJid != null &&
                  fromJidStr.toLowerCase().startsWith(
                    myJid.split('/').first.toLowerCase(),
                  );

              final String archiveSender =
                  stanza.fromJid?.fullJid ?? accountId;
              final String buddyJid =
                  (isSent
                          ? innerMessage.getAttribute('to')?.value ?? archiveSender
                          : fromJidStr ?? archiveSender)
                      .toString();

              final reply = innerMessage.getChild('reply');
              final replyToId = reply?.getAttribute('xmlns')?.value ==
                      'urn:xmpp:reply:0'
                  ? reply?.getAttribute('id')?.value
                  : null;

              _d.messageStreamController.add(
                ChatMessage(
                  id: innerMessage.getAttribute('id')?.value ??
                      mamResult.getAttribute('id')?.value ??
                      'xmpp_${DateTime.now().microsecondsSinceEpoch}',
                  text: body,
                  timestamp: timestamp,
                  isSent: isSent,
                  senderId: fromJidStr,
                  senderName: fromJidStr?.split('@').first,
                  accountId: accountId,
                  protocol: 'XMPP',
                  conversationId: buddyJid.split('/').first.toLowerCase(),
                  replyToId: replyToId,
                  isGroup: buddyJid.contains('conference.') ||
                      buddyJid.startsWith('#'),
                ),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('MAM PARSE ERROR: $e');
      }
    }

    final carbonSent = stanza.getChild('sent');
    final carbonReceived = stanza.getChild('received');
    final carbon = carbonSent ?? carbonReceived;
    if (carbon != null &&
        carbon.getAttribute('xmlns')?.value == 'urn:xmpp:carbons:2') {
      try {
        final forwarded = carbon.getChild('forwarded');
        final innerMessage = forwarded?.getChild('message');
        if (innerMessage != null) {
          final originIdEl = innerMessage.getChild('origin-id');
          final originId = originIdEl?.getAttribute('id')?.value;
          final stanzaId = innerMessage.getAttribute('id')?.value;
          // Primary dedup: origin-id. Fallback: stanza ID if origin-id missing
          if (originId != null && _d.sentOriginIds.containsKey(originId)) {
            debugPrint('XMPP: Carbon echo for origin-id $originId, dropping');
            _d.sentOriginIds.remove(originId);
            return;
          } else if (originId == null && stanzaId != null && _d.sentOriginIds.containsKey(stanzaId)) {
            debugPrint('XMPP: Carbon echo for stanza-id $stanzaId (no origin-id), dropping');
            _d.sentOriginIds.remove(stanzaId);
            return;
          }

          String? body = innerMessage.getChild('body')?.textValue;
          final buddyJid = carbonSent != null
              ? innerMessage.getAttribute('to')?.value
              : innerMessage.getAttribute('from')?.value;

          final encrypted = innerMessage.getChild('encrypted');
          if (encrypted != null && buddyJid != null) {
            final bareJid = buddyJid.split('/').first.toLowerCase();
            final delay = forwarded?.getChild('delay');
            final decrypted = await _d.omemoService.decryptMessage(
              encrypted,
              fromBareJid: bareJid,
              isHistorical: delay != null,
            );
            if (decrypted != null) {
              body = decrypted;
            } else {
              body = '🔒 [Decryption Failed - Rebuilding Session...]';
              _d.refreshOmemoDevices(bareJid);
            }
          }

          if (body != null) {
            final delay = forwarded?.getChild('delay');
            final stamp = delay?.getAttribute('stamp')?.value;
            final timestamp = stamp != null
                ? DateTime.parse(stamp)
                : DateTime.now();

            if (buddyJid != null) {
              _d.messageStreamController.add(
                ChatMessage(
                  id: innerMessage.getAttribute('id')?.value ??
                      originId ??
                      'carbon_${timestamp.millisecondsSinceEpoch}',
                  text: body,
                  timestamp: timestamp,
                  isSent: carbonSent != null,
                  senderId: innerMessage.getAttribute('from')?.value ??
                      innerMessage.getAttribute('to')?.value,
                  accountId: accountId,
                  protocol: 'XMPP',
                  conversationId: buddyJid.split('/').first.toLowerCase(),
                ),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('CARBON PARSE ERROR: $e');
      }
    }
  }
}