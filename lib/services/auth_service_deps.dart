import 'dart:async';
import 'dart:typed_data';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';
import '../models/space_models.dart';
import '../models/user_profile.dart';
import 'database_service.dart';
import 'secure_storage_service.dart';
import 'xmpp_omemo_service.dart';
import 'xmpp_room_service.dart';
import 'otr_service.dart';
import 'offline_queue_service.dart';
import 'jingle_signaling_service.dart';
import 'http_upload_service.dart';

abstract class AuthServiceContactDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  Map<String, String> get xmppJids;
  String? get activeAccountId;
  List<Contact> get currentContacts;
  Map<String, StreamSubscription> get presenceSubs;
  Map<String, StreamSubscription> get rosterSubs;
  StreamController<List<Contact>> get contactStreamController;
  Map<String, StreamSubscription> get xmppMessageSubs;
  Map<String, StreamSubscription> get jingleEventSubs;
  Map<String, StreamSubscription> get xmppStanzaSubs;
  List<SavedAccount> get savedAccounts;
  XmppOmemoService get omemoService;
  XmppRoomService get roomService;
  SecureStorageService get secureStorage;
  List<Map<String, String>> get pendingSubscriptionRequests;
  StreamController<List<Map<String, String>>> get subscriptionRequestController;
  StreamController<ChatMessage> get messageStreamController;
  StreamController<List<SpaceNode>> get joinedSpacesStreamController;
  List<SpaceNode> get cachedJoinedSpaces;
  Map<String, bool> get carbonsEnabled;
  Map<String, List<Map<String, dynamic>>> get accountIceServers;
  Set<String> get pendingVCardFetches;
  Map<String, DateTime> get vCardLastFetch;
  Set<String> get vCardUnsupportedJids;
  Map<String, String> get contactAvatarHashes;
  StreamController<List<String>> get blockedContactsController;
  List<String> get currentBlockedContacts;
  bool get xmppConnecting;
  String? get lastDiagnostic;
  ContactStatus get myStatus;
  String? get myStatusMessage;
  UserProfile? get currentProfile;
  set myStatus(ContactStatus value);
  set myStatusMessage(String? value);
  set xmppConnecting(bool value);
  set lastDiagnostic(String? value);
  set currentProfile(UserProfile? value);
  void notifyListeners();
  void clearVCardState();
  Future<void> fetchMyVCard({String? accountId});
  Future<void> fetchContactVCard(String jid, {String? accountId});
  Future<void> loadSavedAccounts();
  Future<void> setPresence(ContactStatus status, String? message);
  Future<void> saveSubscriptionRequests();
  Future<void> sendMessage(String accountId, String toJid, String text, {String? fileName, String? filePath, bool isGroup = false, String? replyToId, MessageType type = MessageType.text});
  Future<void> connectXmpp({required String user, required String domain, required String pass, required int port, String? host, String? accountId, SavedAccount? configData});
  Future<void> logout();
}

abstract class AuthServiceMessageDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  String? get activeAccountId;
  Map<String, String> get xmppJids;
  XmppOmemoService get omemoService;
  OtrService get otrService;
  OfflineQueueService get offlineQueue;
  StreamController<ChatMessage> get messageStreamController;
  StreamController<JingleEvent> get jingleEventController;
  Map<String, String> get sentOriginIds;
  void trackSentOriginId(String originId, String accountId);
  DatabaseService get databaseService;
  bool get sendReadReceipts;
  bool get sendTypingIndicators;
}

abstract class AuthServiceStanzaDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  Map<String, String> get xmppJids;
  XmppOmemoService get omemoService;
  OtrService get otrService;
  StreamController<ChatMessage> get messageStreamController;
  StreamController<JingleEvent> get jingleEventController;
  Map<String, JingleSignalingService> get jingleServices;
  XmppRoomService get roomService;
  UserProfile? get currentProfile;
  Map<String, String> get sentOriginIds;
  void trackSentOriginId(String originId, String accountId);
  void notifyListeners();
  Future<void> refreshOmemoDevices(String chatId, {String? accountId});
  bool get sendReadReceipts;
  void Function(String jid, String mood, String? text)? onMoodReceived;
  void Function(String jid, String? avatarId)? onAvatarMetadataReceived;
  void Function(String jid, String nickname)? onNicknameReceived;
  void Function(String jid, DateTime lastInteraction)? onLastInteractionReceived;
}

abstract class AuthServiceVCardDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  Map<String, String> get xmppJids;
  String? get activeAccountId;
  UserProfile? get currentProfile;
  set currentProfile(UserProfile? value);
  Set<String> get vCardUnsupportedJids;
  Map<String, DateTime> get vCardLastFetch;
  Set<String> get pendingVCardFetches;
  Map<String, String> get contactAvatarHashes;
  ContactStatus get myStatus;
  String? get myStatusMessage;
  void notifyListeners();
  Future<void> updateMyStatus(ContactStatus status, {String? message});
  Future<void> fetchVCard(String accountId, String jid);
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
  });
  Future<bool> setMyAvatarBytes(String accountId, Uint8List bytes);
}

abstract class AuthServiceSyncDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  Map<String, String> get xmppJids;
  String? get activeAccountId;
  Map<String, bool> get carbonsEnabled;
  Future<void> fetchMyVCard({String? accountId});
}

abstract class PrivacyServiceDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  String? get activeAccountId;
}

abstract class AuthServiceUploadDeps {
  Map<String, xmpp.Connection> get xmppConnections;
  String? get activeAccountId;
  Map<String, HttpUploadService> get uploadServices;
  Future<void> sendMessage(String accountId, String toJid, String text, {String? fileName, String? filePath, bool isGroup, String? replyToId, MessageType type});
}
