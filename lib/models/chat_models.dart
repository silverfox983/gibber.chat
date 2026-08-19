import 'dart:convert';
import 'dart:convert' as json;
import 'dart:typed_data';

enum MessageType { text, image, file, voice, stream, call, system, location }

enum MessageStatus { sending, sent, delivered, read, failed }

enum ContactStatus { online, offline, away, dnd, xa }

enum ConnectionStatus { online, connecting, offline }

class Contact {
  final String id;
  String name;
  final String protocol;
  ContactStatus status;
  String? presenceMessage;
  String? bio;
  String? fullName;
  Uint8List? avatarBytes;
  List<String> groups;
  String? email;
  String? phone;
  String? url;
  String? organization;
  String? title;
  String? role;
  String? birthday;

  Contact({
    required this.id,
    required this.name,
    required this.protocol,
    this.status = ContactStatus.offline,
    this.presenceMessage,
    this.bio,
    this.fullName,
    this.avatarBytes,
    this.groups = const [],
    this.email,
    this.phone,
    this.url,
    this.organization,
    this.title,
    this.role,
    this.birthday,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol,
    'status': status.index,
    'presenceMessage': presenceMessage,
    'bio': bio,
    'fullName': fullName,
    'groups': groups,
    'email': email,
    'phone': phone,
    'url': url,
    'organization': organization,
    'title': title,
    'role': role,
    'birthday': birthday,
  };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    id: json['id'],
    name: json['name'],
    protocol: json['protocol'] ?? 'XMPP',
    status: ContactStatus.values[(json['status'] as int?)?.clamp(0, ContactStatus.values.length - 1) ?? ContactStatus.offline.index],
    presenceMessage: json['presenceMessage'] as String?,
    bio: json['bio'] as String?,
    fullName: json['fullName'] as String?,
    groups: List<String>.from(json['groups'] ?? []),
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    url: json['url'] as String?,
    organization: json['organization'] as String?,
    title: json['title'] as String?,
    role: json['role'] as String?,
    birthday: json['birthday'] as String?,
  );
}

class ChatMessage {
  dynamic get senderColor => null;
  final String id;
  String text;
  final DateTime timestamp;
  final bool isSent;
  final MessageType type;
  final String? filePath;
  final String? fileName;

  final String? senderId;
  final String? senderName;
  final String? accountId;
  final String? protocol;
  final String? conversationId;
  final bool isGroup;
  MessageStatus status;
  final String? replyToId;
  final String? replyPreview;
  final String? replacesId;
  final Map<String, List<String>> reactions;
  bool isEdited;
  DateTime? editTimestamp;
  final String? forwardedFrom;
  final String? encryptionType;
  final double? latitude;
  final double? longitude;
  final String? locationLabel;

  ChatMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    required this.isSent,
    this.type = MessageType.text,
    this.filePath,
    this.fileName,
    this.senderId,
    this.senderName,
    this.accountId,
    this.protocol,
    String? conversationId,
    this.isGroup = false,
    this.status = MessageStatus.sent,
    this.replyToId,
    this.replyPreview,
    this.replacesId,
    Map<String, List<String>>? reactions,
    this.isEdited = false,
    this.editTimestamp,
    this.forwardedFrom,
    this.encryptionType,
    this.latitude,
    this.longitude,
    this.locationLabel,
  }) : conversationId = conversationId?.split('/').first.toLowerCase(),
       reactions = _dedupeReactionMap(reactions ?? const {});

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'text': text,
      'timestamp': timestamp.toIso8601String(),
      'is_sent': isSent ? 1 : 0,
      'type': type.index,
      'file_path': filePath,
      'file_name': fileName,
      'sender_id': senderId,
      'sender_name': senderName,
      'account_id': accountId,
      'protocol': protocol,
      'conversation_id': conversationId,
      'is_group': isGroup ? 1 : 0,
      'status': status.index,
      'reply_to_id': replyToId,
      'reply_preview': replyPreview,
      'replaces_id': replacesId,
      'reactions_json': reactions.isEmpty ? null : _encodeReactions(reactions),
      'is_edited': isEdited ? 1 : 0,
      'edit_timestamp': editTimestamp?.toIso8601String(),
      'reactions': reactions.isNotEmpty ? jsonEncode(reactions) : null,
      'forwarded_from': forwardedFrom,
      'encryption_type': encryptionType,
      'latitude': latitude,
      'longitude': longitude,
      'location_label': locationLabel,
    };
  }

  static String _encodeReactions(Map<String, List<String>> reactions) {
    final safe = reactions.map(
      (key, value) => MapEntry(key, List<String>.from(value)),
    );
    return json.jsonEncode(safe);
  }

  static Map<String, List<String>> _decodeReactions(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map<String, dynamic>) {
      return _dedupeReactionMap(
        raw.map(
          (key, value) => MapEntry(key, List<String>.from(value as List)),
        ),
      );
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        // Stored as JSON string in DB.
        final dynamic decoded = _jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return _dedupeReactionMap(
            decoded.map(
              (key, value) => MapEntry(key, List<String>.from(value as List)),
            ),
          );
        }
      } catch (_) {
        return {};
      }
    }
    return {};
  }

  static Map<String, List<String>> _dedupeReactionMap(
    Map<String, List<String>> raw,
  ) {
    return raw.map((emoji, senders) {
      final seen = <String>{};
      final deduped = <String>[];
      for (final sender in senders) {
        final id = sender.trim();
        if (id.isEmpty) continue;
        if (seen.add(id)) {
          deduped.add(id);
        }
      }
      return MapEntry(emoji, deduped);
    });
  }

  static dynamic _jsonDecode(String value) {
    // Avoid top-level dart:convert import churn in this shared model file.
    return const _ChatJsonCodec().decode(value);
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] ?? 'msg_${DateTime.now().microsecondsSinceEpoch}',
      text: map['text'] ?? '',
      timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      isSent: map['is_sent'] == 1,
      type: MessageType.values[map['type'] ?? 0],
      filePath: map['file_path'],
      fileName: map['file_name'],
      senderId: map['sender_id'],
      senderName: map['sender_name'],
      accountId: map['account_id'],
      protocol: map['protocol'] ?? 'XMPP',
      conversationId: map['conversation_id'] ?? '',
      isGroup: (map['is_group'] ?? 0) == 1,
      status: MessageStatus.values[map['status'] ?? 1],
      replyToId: map['reply_to_id'],
      replyPreview: map['reply_preview'],
      replacesId: map['replaces_id'],
      reactions: _decodeReactions(map['reactions_json']),
      isEdited: map['is_edited'] == 1,
      editTimestamp: map['edit_timestamp'] != null
          ? DateTime.tryParse(map['edit_timestamp'])
          : null,
      forwardedFrom: map['forwarded_from'],
      encryptionType: map['encryption_type'],
      latitude: map['latitude'] != null ? (map['latitude'] as num).toDouble() : null,
      longitude: map['longitude'] != null ? (map['longitude'] as num).toDouble() : null,
      locationLabel: map['location_label'],
    );
  }
}

class _ChatJsonCodec {
  const _ChatJsonCodec();

  dynamic decode(String value) {
    return json.jsonDecode(value);
  }
}

class Conversation {
  final String id;
  final String name;
  final String? avatarUrl;
  final List<ChatMessage> messages;
  final String protocol; // 'XMPP' or 'IRC'
  final String? accountId;
  bool isTyping;
  String? typingUser;
  int unreadCount;
  ContactStatus status;
  String? presenceMessage;
  Uint8List? avatarBytes;
  List<RoomParticipant> participants;
  String? wallpaperPath;
  int? wallpaperColor;
  String? topic;
  String? draft;
  String? encryptionType;
  String? pinnedMessageId;
  String? pinnedMessageText;

  Conversation({
    required this.id,
    required this.name,
    this.avatarUrl,
    required this.messages,
    required this.protocol,
    this.accountId,
    this.isGroup = false,
    this.historyLoaded = false,
    this.isTyping = false,
    this.typingUser,
    this.unreadCount = 0,
    this.status = ContactStatus.offline,
    this.presenceMessage,
    this.participants = const [],
    this.wallpaperPath,
    this.wallpaperColor,
    this.topic,
    this.draft,
    this.encryptionType,
    this.pinnedMessageId,
    this.pinnedMessageText,
  });

  bool isGroup;
  bool historyLoaded;

  ChatMessage? get lastMessage => messages.isNotEmpty ? messages.last : null;
}

class RoomParticipant {
  final String nickname;
  final String? realJid;
  final String? affiliation;
  final String? role;

  RoomParticipant({
    required this.nickname,
    this.realJid,
    this.affiliation,
    this.role,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoomParticipant &&
          runtimeType == other.runtimeType &&
          nickname == other.nickname;

  @override
  int get hashCode => nickname.hashCode;
}

class Room {
  final String id;
  final String name;
  final String? topic;
  final List<RoomParticipant> participants;
  final String protocol;
  final bool isGroup;
  final String? accountId;

  Room({
    required this.id,
    required this.name,
    this.topic,
    required this.participants,
    required this.protocol,
    this.isGroup = false,
    this.accountId,
  });
}

class SavedAccount {
  final String user;
  final String domain;
  final String? host;
  final int port;
  final String protocol;
  final String? displayName;

  // Advanced Protocol Preferences
  final List<String>? autoJoinChannels;
  final String? customResource;
  final bool? useTor;
  final bool? isSecure;
  final String? realName;
  final String? serverPassword;
  final String? saslAuthPassword;
  final String? wsPath;
  final bool? ackEnabled;
  final bool? smResumable;
  final int? reconnectionTimeout;

  SavedAccount({
    required this.user,
    required this.domain,
    this.host,
    required this.port,
    required this.protocol,
    this.displayName,
    this.autoJoinChannels,
    this.customResource,
    this.useTor,
    this.isSecure,
    this.realName,
    this.serverPassword,
    this.saslAuthPassword,
    this.wsPath,
    this.ackEnabled,
    this.smResumable,
    this.reconnectionTimeout,
  });

  String get fullJid => user.contains('@') ? user : '$user@$domain';

  Map<String, dynamic> toJson() => {
    'user': user,
    'domain': domain,
    'host': host,
    'port': port,
    'protocol': protocol,
    'displayName': displayName,
    'autoJoinChannels': autoJoinChannels,
    'customResource': customResource,
    'useTor': useTor,
    'isSecure': isSecure,
    'realName': realName,
    'serverPassword': serverPassword,
    'saslAuthPassword': saslAuthPassword,
    'wsPath': wsPath,
    'ackEnabled': ackEnabled,
    'smResumable': smResumable,
    'reconnectionTimeout': reconnectionTimeout,
  };

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
    user: json['user'],
    domain: json['domain'],
    host: json['host'],
    port: json['port'],
    protocol: json['protocol'],
    displayName: json['displayName'],
    autoJoinChannels: json['autoJoinChannels'] != null
        ? List<String>.from(json['autoJoinChannels'])
        : null,
    customResource: json['customResource'],
    useTor: json['useTor'],
    isSecure: json['isSecure'],
    realName: json['realName'],
    serverPassword: json['serverPassword'],
    saslAuthPassword: json['saslAuthPassword'],
    wsPath: json['wsPath'],
    ackEnabled: json['ackEnabled'],
    smResumable: json['smResumable'],
    reconnectionTimeout: json['reconnectionTimeout'],
  );
}
