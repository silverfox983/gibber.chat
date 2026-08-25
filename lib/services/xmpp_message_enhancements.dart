import 'package:flutter/material.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

class XmppMessageEnhancements {
  static void addEncryptionIndicator(xmpp.MessageStanza msg, String namespace, {String? name}) {
    final encryption = xmpp.XmppElement();
    encryption.name = 'encryption';
    encryption.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:encryption:0'));
    encryption.addAttribute(xmpp.XmppAttribute('namespace', namespace));
    if (name != null) {
      encryption.addAttribute(xmpp.XmppAttribute('name', name));
    }
    msg.addChild(encryption);
  }

  static void addStoreHint(xmpp.MessageStanza msg) {
    final hint = xmpp.XmppElement();
    hint.name = 'store';
    hint.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
    msg.addChild(hint);
  }

  static void addNoPermanentStoreHint(xmpp.MessageStanza msg) {
    final hint = xmpp.XmppElement();
    hint.name = 'no-permanent-store';
    hint.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
    msg.addChild(hint);
  }

  static void addNoStoreHint(xmpp.MessageStanza msg) {
    final hint = xmpp.XmppElement();
    hint.name = 'no-store';
    hint.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
    msg.addChild(hint);
  }

  static void addNoCopiesHint(xmpp.MessageStanza msg) {
    final hint = xmpp.XmppElement();
    hint.name = 'no-copies';
    hint.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:hints'));
    msg.addChild(hint);
  }

  static void addMessageThreadId(xmpp.MessageStanza msg, String threadId) {
    final thread = xmpp.XmppElement();
    thread.name = 'thread';
    thread.textValue = threadId;
    msg.addChild(thread);
  }

  static void addFallbackIndicator(xmpp.MessageStanza msg, String fallbackBody, {int? forAttr}) {
    final fallback = xmpp.XmppElement();
    fallback.name = 'fallback';
    fallback.addAttribute(xmpp.XmppAttribute('xmlns', 'urn:xmpp:fallback:0'));
    if (forAttr != null) {
      fallback.addAttribute(xmpp.XmppAttribute('for', forAttr.toString()));
    }
    msg.addChild(fallback);
  }

  static EncryptionInfo? parseEncryptionIndicator(xmpp.MessageStanza stanza) {
    for (var child in stanza.children.whereType<xmpp.XmppElement>()) {
      if (child.name == 'encryption' &&
          child.getAttribute('xmlns')?.value == 'urn:xmpp:encryption:0') {
        return EncryptionInfo(
          namespace: child.getAttribute('namespace')?.value ?? '',
          name: child.getAttribute('name')?.value,
        );
      }
    }
    return null;
  }

  static bool hasNoStoreHint(xmpp.MessageStanza stanza) {
    return stanza.children.any((e) =>
        e.name == 'no-store' &&
        e.getAttribute('xmlns')?.value == 'urn:xmpp:hints');
  }

  static bool hasNoPermanentStoreHint(xmpp.MessageStanza stanza) {
    return stanza.children.any((e) =>
        e.name == 'no-permanent-store' &&
        e.getAttribute('xmlns')?.value == 'urn:xmpp:hints');
  }

  static bool hasNoCopiesHint(xmpp.MessageStanza stanza) {
    return stanza.children.any((e) =>
        e.name == 'no-copies' &&
        e.getAttribute('xmlns')?.value == 'urn:xmpp:hints');
  }

  static String? parseThreadId(xmpp.MessageStanza stanza) {
    for (var child in stanza.children.whereType<xmpp.XmppElement>()) {
      if (child.name == 'thread') {
        return child.textValue;
      }
    }
    return null;
  }
}

class EncryptionInfo {
  final String namespace;
  final String? name;

  EncryptionInfo({required this.namespace, this.name});

  String get displayName {
    switch (namespace) {
      case 'urn:xmpp:omemo:0':
        return 'OMEMO';
      case 'urn:xmpp:otr:0':
        return 'OTR';
      case 'urn:xmpp:openpgp:0':
        return 'OpenPGP';
      default:
        return name ?? namespace;
    }
  }
}

class XmppMessageStyling {
  static const String nsStyling = 'urn:xmpp:styling:0';

  static const Map<String, String> stylingMarkers = {
    '*': 'emphasis',
    '_': 'emphasis',
    '~': 'strikethrough',
    '`': 'pre',
    '>': 'blockquote',
  };

  static List<StyledSpan> parseMessageStyling(String text) {
    final spans = <StyledSpan>[];
    int pos = 0;

    while (pos < text.length) {
      if (text[pos] == '*' && _findClosing(text, pos, '*')) {
        final end = _findClosingIndex(text, pos, '*');
        if (end != null) {
          spans.add(StyledSpan(
            text: text.substring(pos + 1, end),
            style: StylingType.emphasis,
            start: pos,
            end: end + 1,
          ));
          pos = end + 1;
          continue;
        }
      } else if (text[pos] == '~' && _findClosing(text, pos, '~')) {
        final end = _findClosingIndex(text, pos, '~');
        if (end != null) {
          spans.add(StyledSpan(
            text: text.substring(pos + 1, end),
            style: StylingType.strikethrough,
            start: pos,
            end: end + 1,
          ));
          pos = end + 1;
          continue;
        }
      } else if (text[pos] == '`' && _findClosing(text, pos, '`')) {
        final end = _findClosingIndex(text, pos, '`');
        if (end != null) {
          spans.add(StyledSpan(
            text: text.substring(pos + 1, end),
            style: StylingType.pre,
            start: pos,
            end: end + 1,
          ));
          pos = end + 1;
          continue;
        }
      }
      pos++;
    }

    return spans;
  }

  static bool _findClosing(String text, int start, String marker) {
    return _findClosingIndex(text, start, marker) != null;
  }

  static int? _findClosingIndex(String text, int start, String marker) {
    final nextStart = start + 1;
    if (nextStart >= text.length) return null;
    final end = text.indexOf(marker, nextStart);
    if (end > start && end < text.length) {
      if (end + 1 >= text.length || text[end + 1] == ' ' || text[end + 1] == '\n') {
        return end;
      }
    }
    return null;
  }

  static InlineUrl? parseInlineUrl(String text, int startPos) {
    final urlRegex = RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+');
    final match = urlRegex.firstMatch(text.substring(startPos));
    if (match != null && match.start == 0) {
      return InlineUrl(
        url: match.group(0)!,
        start: startPos,
        end: startPos + match.group(0)!.length,
      );
    }
    return null;
  }

  static MentionMatch? parseMention(String text, int startPos) {
    final mentionRegex = RegExp(r'@[\w.-]+@[\w.-]+');
    final match = mentionRegex.firstMatch(text.substring(startPos));
    if (match != null && match.start == 0) {
      return MentionMatch(
        jid: match.group(0)!.substring(1),
        start: startPos,
        end: startPos + match.group(0)!.length,
      );
    }
    return null;
  }
}

enum StylingType { emphasis, strikethrough, pre, blockquote }

class StyledSpan {
  final String text;
  final StylingType style;
  final int start;
  final int end;

  StyledSpan({
    required this.text,
    required this.style,
    required this.start,
    required this.end,
  });
}

class InlineUrl {
  final String url;
  final int start;
  final int end;

  InlineUrl({required this.url, required this.start, required this.end});
}

class MentionMatch {
  final String jid;
  final int start;
  final int end;

  MentionMatch({required this.jid, required this.start, required this.end});
}