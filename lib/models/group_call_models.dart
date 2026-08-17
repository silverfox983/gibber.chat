enum GroupCallStatus {
  idle,
  joining,
  active,
  leaving,
  ended,
  failed,
}

class JanusParticipant {
  final String id;
  final String displayName;
  final String jid;
  final bool audioEnabled;
  final bool videoEnabled;
  final bool speaking;

  const JanusParticipant({
    required this.id,
    required this.displayName,
    required this.jid,
    this.audioEnabled = true,
    this.videoEnabled = true,
    this.speaking = false,
  });

  JanusParticipant copyWith({
    String? id,
    String? displayName,
    String? jid,
    bool? audioEnabled,
    bool? videoEnabled,
    bool? speaking,
  }) =>
      JanusParticipant(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        jid: jid ?? this.jid,
        audioEnabled: audioEnabled ?? this.audioEnabled,
        videoEnabled: videoEnabled ?? this.videoEnabled,
        speaking: speaking ?? this.speaking,
      );
}

class GroupCallSession {
  final String roomId;
  final String roomJid;
  final String accountId;
  final String janusSessionId;
  final String publisherHandle;
  final String displayName;
  final bool isAudioOnly;
  final DateTime startedAt;
  final String? sfuUrl;

  GroupCallStatus status;
  String? publisherStreamId;
  Map<String, JanusParticipant> participants;
  String? errorMessage;

  GroupCallSession({
    required this.roomId,
    required this.roomJid,
    required this.accountId,
    required this.janusSessionId,
    required this.publisherHandle,
    required this.displayName,
    this.isAudioOnly = false,
    this.sfuUrl,
    this.status = GroupCallStatus.joining,
    DateTime? startedAt,
    Map<String, JanusParticipant>? participants,
    this.publisherStreamId,
    this.errorMessage,
  })  : startedAt = startedAt ?? DateTime.now(),
        participants = participants ?? {};

  GroupCallSession copyWith({
    GroupCallStatus? status,
    String? publisherStreamId,
    String? errorMessage,
    Map<String, JanusParticipant>? participants,
  }) =>
      GroupCallSession(
        roomId: roomId,
        roomJid: roomJid,
        accountId: accountId,
        janusSessionId: janusSessionId,
        publisherHandle: publisherHandle,
        displayName: displayName,
        isAudioOnly: isAudioOnly,
        sfuUrl: sfuUrl,
        status: status ?? this.status,
        startedAt: startedAt,
        participants: participants ?? this.participants,
        publisherStreamId: publisherStreamId ?? this.publisherStreamId,
        errorMessage: errorMessage ?? this.errorMessage,
      );

  Duration get duration => DateTime.now().difference(startedAt);

  int get participantCount => participants.length;
}