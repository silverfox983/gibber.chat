import 'dart:convert';
import 'dart:typed_data';

enum MessageType { text, image, file, voice, stream, call, system }

enum MessageStatus { sending, sent, delivered, read }

enum ContactStatus { online, offline, away, dnd, xa }

enum ConnectionStatus { online, connecting, offline }

class Contact {
  final String id;
  String name;
  final String protocol;
  ContactStatus status;
  String? presenceMessage;
  Uint8List? avatarBytes;

  Contact({
    required this.id,
    required this.name,
    required this.protocol,
    this.status = ContactStatus.offline,
    this.presenceMessage,
    this.avatarBytes,
  });
}

class ChatMessage {
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
  final String? replacesId;
  final Map<String, List<String>> reactions;
  bool isEdited;
  DateTime? editTimestamp;

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
    this.replacesId,
    this.reactions = const {},
    this.isEdited = false,
    this.editTimestamp,
  }) : conversationId = conversationId?.split('/').first.toLowerCase();

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
      'replaces_id': replacesId,
      'is_edited': isEdited ? 1 : 0,
      'edit_timestamp': editTimestamp?.toIso8601String(),
      'reactions': reactions.isNotEmpty ? jsonEncode(reactions) : null,
    };
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
      replacesId: map['replaces_id'],
      isEdited: map['is_edited'] == 1,
      editTimestamp: map['edit_timestamp'] != null
          ? DateTime.tryParse(map['edit_timestamp'])
          : null,
      reactions: map['reactions'] != null
          ? (jsonDecode(map['reactions']) as Map<String, dynamic>).map(
              (k, v) => MapEntry(k, List<String>.from(v)),
            )
          : {},
    );
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
  List<String> participants;
  String? wallpaperPath;
  int? wallpaperColor;
  String? topic;

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
  });

  bool isGroup;
  bool historyLoaded;

  ChatMessage? get lastMessage => messages.isNotEmpty ? messages.last : null;
}

class Room {
  final String id;
  final String name;
  final String? topic;
  final List<String> participants;
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
