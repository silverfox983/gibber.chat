import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';
import 'auth_service_deps.dart';
import 'otr_service.dart';
import 'offline_queue_service.dart';
import 'jingle_signaling_service.dart';
import 'xmpp_omemo_service.dart';

class XmppMessageService {
  final AuthServiceMessageDeps _d;

  XmppMessageService(this._d);

  Future<void> sendXmppMessage(
    String targetJid,
    String text, {
    String? accountId,
    MessageType type = MessageType.text,
    String? filePath,
    String? fileName,
    String? replyToId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    final isOmemo = _d.omemoService.isOmemoEnabled(targetJid);
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      final bareTarget = targetJid.split('/').first;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

      final originId = msg.id ?? 'msg_${DateTime.now().microsecondsSinceEpoch}';
      final originIdEl = xmpp.XmppElement();
      originIdEl.name = 'origin-id';
      originIdEl.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:sid:0'));
      originIdEl.addAttribute(xmpp.XmppAttribute('id', originId));
      msg.addChild(originIdEl);
      _d.sentOriginIds[originId] = id ?? _d.activeAccountId ?? '';

      if (isOmemo) {
        final encryptedList = await _d.omemoService.encryptMessage(
          targetJid,
          text,
          strict: _d.omemoService.isStrictVerificationEnabled,
        );
        if (encryptedList != null && encryptedList.isNotEmpty) {
          for (var enc in encryptedList) {
            msg.addChild(enc);
          }
          msg.body = '🔒 This message is encrypted with OMEMO.';
        } else {
          throw Exception(
            'OMEMO Encryption Failed: The recipient ($targetJid) does not have any OMEMO-capable devices. '
            'Please disable OMEMO for this contact in the chat settings to send unencrypted messages.',
          );
        }
      } else {
        msg.body = isGroup
            ? text
            : _d.otrService.processOutgoingMessage(bareTarget, text);
      }

      if (replyToId != null) {
        final reply = xmpp.XmppElement();
        reply.name = 'reply';
        reply.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:reply:0'));
        reply.addAttribute(xmpp.XmppAttribute('to', targetJid));
        reply.addAttribute(xmpp.XmppAttribute('id', replyToId));
        msg.addChild(reply);
      }

      if (!isGroup) {
        final requestEl = xmpp.XmppElement();
        requestEl.name = 'request';
        requestEl.addAttribute(
          xmpp.XmppAttribute('xmlns', 'urn:xmpp:receipts'),
        );
        msg.addChild(requestEl);
      }

      conn.writeStanza(msg);

      _d.messageStreamController.add(
        ChatMessage(
          id: msg.id ?? 'xmpp_${DateTime.now().microsecondsSinceEpoch}',
          text: text,
          timestamp: DateTime.now(),
          isSent: true,
          senderId: _d.xmppJids[id] ?? 'me',
          accountId: id,
          protocol: 'XMPP',
          conversationId: targetJid.split('/').first.toLowerCase(),
          type: type,
          filePath: filePath,
          fileName: fileName,
          isGroup: isGroup,
          status: MessageStatus.sending,
          encryptionType: isOmemo ? 'omemo' : null,
        ),
      );
    } else {
      final qid = await _d.offlineQueue.enqueue(
        targetJid: targetJid,
        text: text,
        accountId: id ?? _d.activeAccountId ?? '',
        type: type,
        filePath: filePath,
        fileName: fileName,
        replyToId: replyToId,
        isGroup: isGroup,
        encryptionType: isOmemo ? 'omemo' : null,
      );
      _d.messageStreamController.add(
        ChatMessage(
          id: qid,
          text: text,
          timestamp: DateTime.now(),
          isSent: true,
          senderId: _d.xmppJids[id] ?? 'me',
          accountId: id,
          protocol: 'XMPP',
          conversationId: targetJid.split('/').first.toLowerCase(),
          type: type,
          filePath: filePath,
          fileName: fileName,
          isGroup: isGroup,
          status: MessageStatus.sending,
          encryptionType: isOmemo ? 'omemo' : null,
        ),
      );
      debugPrint('XMPP: Message queued offline (id: $qid, target: $targetJid)');
    }
  }

  Future<void> flushPendingMessages(String accountId) async {
    final pending = await _d.offlineQueue.getPendingForAccount(accountId);
    if (pending.isEmpty) return;

    debugPrint('XMPP: Flushing ${pending.length} pending messages for account $accountId');

    for (final row in pending) {
      final id = row['id'] as String;
      final targetJid = row['target_jid'] as String;
      final text = row['text'] as String;
      final messageType = MessageType.values[(row['message_type'] as int?) ?? 0];
      final filePath = row['file_path'] as String?;
      final fileName = row['file_name'] as String?;
      final replyToId = row['reply_to_id'] as String?;
      final isGroup = (row['is_group'] as int?) == 1;

      final conn = _d.xmppConnections[accountId];
      if (conn == null || (conn.state != xmpp.XmppConnectionState.Ready && conn.state != xmpp.XmppConnectionState.Resumed)) {
        debugPrint('XMPP: Connection lost during flush, will retry later');
        await _d.offlineQueue.incrementRetryCount(id);
        return;
      }

      try {
        await sendXmppMessage(
          targetJid,
          text,
          accountId: accountId,
          type: messageType,
          filePath: filePath,
          fileName: fileName,
          replyToId: replyToId,
          isGroup: isGroup,
        );
        await _d.offlineQueue.dequeue(id);
        debugPrint('XMPP: Flushed pending message $id');
      } catch (e) {
        debugPrint('XMPP: Failed to flush pending message $id: $e');
        await _d.offlineQueue.incrementRetryCount(id);
      }
    }

    await _d.offlineQueue.removeOldRetries();
  }

  Future<void> sendEditedMessage(
    String targetJid,
    String originalMsgId,
    String newText, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);
      msg.body = newText;

      final replace = xmpp.XmppElement();
      replace.name = 'replace';
      replace.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:message-correct:0'),
      );
      replace.addAttribute(xmpp.XmppAttribute('id', originalMsgId));
      msg.addChild(replace);

      conn.writeStanza(msg);
      debugPrint('AuthService: Sent edited message for $originalMsgId');
    }
  }

  void sendChatMarker(
    String targetJid,
    String msgId,
    String markerType, {
    String? accountId,
    bool isGroup = false,
  }) {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

      final marker = xmpp.XmppElement();
      marker.name = markerType;
      marker.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:chat-markers:0'),
      );
      marker.addAttribute(xmpp.XmppAttribute('id', msgId));
      msg.addChild(marker);

      conn.writeStanza(msg);
    }
  }

  Future<void> sendXmppReaction(
    String targetJid,
    String originalMsgId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

      final reactions = xmpp.XmppElement();
      reactions.name = 'reactions';
      reactions.addAttribute(
        xmpp.XmppAttribute('xmlns', 'urn:xmpp:reactions:0'),
      );
      reactions.addAttribute(xmpp.XmppAttribute('id', originalMsgId));

      final reaction = xmpp.XmppElement();
      reaction.name = 'reaction';
      reaction.textValue = emoji;
      reactions.addChild(reaction);

      msg.addChild(reactions);
      conn.writeStanza(msg);

      _d.jingleEventController.add(
        JingleEvent(
          action: JingleAction.transportInfo,
          sessionId: 'reaction',
          fromJid: _d.xmppJids[id] ?? 'me',
          reason: originalMsgId,
          sdp: emoji,
          accountId: id,
        ),
      );
    }
  }

  void sendReaction(
    String chatId,
    String messageId,
    String emoji, {
    String? accountId,
    bool isGroup = false,
  }) {
    final activeId = accountId ?? _d.activeAccountId;
    if (_d.xmppConnections.containsKey(activeId)) {
      sendXmppReaction(
        chatId,
        messageId,
        emoji,
        accountId: activeId,
        isGroup: isGroup,
      );
    }
  }

  Future<void> sendMessage(
    String accountId,
    String toId,
    String text, {
    MessageType type = MessageType.text,
    String? fileName,
    String? filePath,
    String? replyToId,
    bool isGroup = false,
  }) async {
    final conn = _d.xmppConnections[accountId];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      await sendXmppMessage(
        toId,
        text,
        accountId: accountId,
        type: type,
        filePath: filePath,
        fileName: fileName,
        replyToId: replyToId,
        isGroup: isGroup,
      );
    } else {
      final qid = await _d.offlineQueue.enqueue(
        targetJid: toId,
        text: text,
        accountId: accountId,
        type: type,
        filePath: filePath,
        fileName: fileName,
        replyToId: replyToId,
        isGroup: isGroup,
      );
      _d.messageStreamController.add(
        ChatMessage(
          id: qid,
          text: text,
          timestamp: DateTime.now(),
          isSent: true,
          senderId: _d.xmppJids[accountId] ?? 'me',
          accountId: accountId,
          protocol: 'XMPP',
          conversationId: toId.split('/').first.toLowerCase(),
          type: type,
          filePath: filePath,
          fileName: fileName,
          isGroup: isGroup,
          status: MessageStatus.sending,
        ),
      );
      debugPrint('XMPP: Message queued offline via sendMessage (id: $qid, target: $toId)');
    }
  }

  Future<void> retractXmppMessage(
    String targetJid,
    String messageId, {
    String? accountId,
    bool isGroup = false,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn == null) return;

    final msg = xmpp.MessageStanza(
      'retract_${DateTime.now().millisecondsSinceEpoch}',
      isGroup ? xmpp.MessageStanzaType.GROUPCHAT : xmpp.MessageStanzaType.CHAT,
    );
    final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
    msg.toJid = xmpp.Jid.fromFullJid(finalTarget);

    final applyTo = xmpp.XmppElement();
    applyTo.name = 'apply-to';
    applyTo.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:fasten:0'));
    applyTo.addAttribute(xmpp.XmppAttribute('id', messageId));

    final retract = xmpp.XmppElement();
    retract.name = 'retract';
    retract.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:retract:0'));
    applyTo.addChild(retract);
    msg.addChild(applyTo);

    conn.writeStanza(msg);
    debugPrint('XMPP: Retracted message $messageId for $targetJid');
  }

  void sendChatState(
    String targetJid,
    String state, {
    String? accountId,
    bool isGroup = false,
  }) {
    final id = accountId ?? _d.activeAccountId;
    final conn = _d.xmppConnections[id];
    if (conn != null &&
        (conn.state == xmpp.XmppConnectionState.Ready ||
            conn.state == xmpp.XmppConnectionState.Resumed)) {
      final msg = xmpp.MessageStanza(
        DateTime.now().millisecondsSinceEpoch.toString(),
        isGroup
            ? xmpp.MessageStanzaType.GROUPCHAT
            : xmpp.MessageStanzaType.CHAT,
      );
      final finalTarget = isGroup ? targetJid.split('/').first : targetJid;
      msg.toJid = xmpp.Jid.fromFullJid(finalTarget);
      final stateEl = xmpp.XmppElement();
      stateEl.name = state;
      stateEl.addAttribute(
        xmpp.XmppAttribute('xmlns', 'http://jabber.org/protocol/chatstates'),
      );
      msg.addChild(stateEl);

      final hint = xmpp.XmppElement();
      hint.name = 'no-store';
      hint.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
      msg.addChild(hint);

      conn.writeStanza(msg);
    }
  }

  Future<void> forwardMessage(
    ChatMessage original,
    List<String> targetChatIds, {
    String? accountId,
    String? targetProtocol,
  }) async {
    final curAccountId = accountId ?? _d.activeAccountId;
    if (curAccountId == null) return;
    for (var targetId in targetChatIds) {
      await Future.delayed(const Duration(milliseconds: 100));
      await sendXmppMessage(
        targetId,
        original.text,
        accountId: curAccountId,
        type: original.type,
        fileName: original.fileName,
        filePath: original.filePath,
      );
    }
  }
}