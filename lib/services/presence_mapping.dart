import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;

import '../models/chat_models.dart';

/// Single source of truth for XMPP presence-show <-> ContactStatus mapping.
xmpp.PresenceShowElement mapStatusToPresenceShow(ContactStatus status) {
  switch (status) {
    case ContactStatus.online:
      return xmpp.PresenceShowElement.CHAT;
    case ContactStatus.away:
      return xmpp.PresenceShowElement.AWAY;
    case ContactStatus.xa:
      return xmpp.PresenceShowElement.XA;
    case ContactStatus.dnd:
      return xmpp.PresenceShowElement.DND;
    case ContactStatus.offline:
      return xmpp.PresenceShowElement.XA;
  }
}

ContactStatus mapPresenceShowToStatus(xmpp.PresenceShowElement? show) {
  if (show == null || show == xmpp.PresenceShowElement.CHAT) {
    return ContactStatus.online;
  } else if (show == xmpp.PresenceShowElement.AWAY) {
    return ContactStatus.away;
  } else if (show == xmpp.PresenceShowElement.XA) {
    return ContactStatus.xa;
  } else if (show == xmpp.PresenceShowElement.DND) {
    return ContactStatus.dnd;
  }
  return ContactStatus.offline;
}