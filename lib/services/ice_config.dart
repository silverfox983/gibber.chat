/// Shared WebRTC configuration constants used by both single-peer and
/// multi-peer call managers.
///
/// The TURN credentials are public openrelay fallbacks; they should come from
/// backend config (`iceServers`) once account provisioning provides them.
const fallbackIceServers = <Map<String, dynamic>>[
  {'urls': 'stun:stun.l.google.com:19302'},
  {'urls': 'stun:stun1.l.google.com:19302'},
  {
    'urls': 'turn:openrelay.metered.ca:80',
    'username': 'openrelayproject',
    'credential': 'openrelayproject',
  },
  {
    'urls': 'turn:openrelay.metered.ca:443',
    'username': 'openrelayproject',
    'credential': 'openrelayproject',
  },
];

const Map<String, dynamic> defaultRtcConfiguration = {
  'iceServers': fallbackIceServers,
  'iceTransportPolicy': 'all',
  'sdpSemantics': 'unified-plan',
  'iceCandidatePoolSize': 10,
};