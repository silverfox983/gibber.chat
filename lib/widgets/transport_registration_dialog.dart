import 'package:flutter/material.dart';

import '../services/transport_service.dart';
import 'gateways/gateway_registration_sheet.dart';

/// Kept for backwards compatibility: delegates to the per-protocol
/// registration sheet (QR pairing / chat-command flows / channel pickers).
Future<bool?> showTransportRegistrationDialog({
  required BuildContext context,
  required TransportService transportService,
  required String gatewayJid,
  required String gatewayName,
}) async {
  return showGatewayRegistrationSheet(
    context: context,
    transportService: transportService,
    gatewayJid: gatewayJid,
    gatewayName: gatewayName,
  );
}