import 'dart:async';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import '../models/chat_models.dart';
import '../models/space_models.dart';
import '../models/user_profile.dart';
import 'secure_storage_service.dart';
import 'xmpp_omemo_service.dart';
import 'xmpp_room_service.dart';
import 'otr_service.dart';
import 'offline_queue_service.dart';
import 'jingle_signaling_service.dart';

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
  Future<void> loadSavedAccounts();
  Future<void> setPresence(ContactStatus status, String? message);
  Future<void> fetchMyVCard({String? accountId});
  Future<void> fetchContactVCard(String jid, {String? accountId});
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
  void notifyListeners();
  Future<void> refreshOmemoDevices(String chatId, {String? accountId});
}
