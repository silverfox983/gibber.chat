class TransportNode {
  final String jid;
  final String name;
  final String type; // e.g., 'discord', 'irc', 'sms'

  TransportNode({
    required this.jid,
    required this.name,
    required this.type,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportNode &&
          runtimeType == other.runtimeType &&
          jid == other.jid &&
          name == other.name &&
          type == other.type;

  @override
  int get hashCode => Object.hash(jid, name, type);

  TransportNode copyWith({String? jid, String? name, String? type}) =>
      TransportNode(jid: jid ?? this.jid, name: name ?? this.name, type: type ?? this.type);
}

class FormFieldOption {
  final String label;
  final String value;

  FormFieldOption({required this.label, required this.value});
}

class FormField {
  final String varName;
  final String type; // 'text-single', 'text-private', 'hidden', 'list-single', 'boolean', etc.
  final String? label;
  final String? value;
  final List<FormFieldOption>? options;

  FormField({
    required this.varName,
    required this.type,
    this.label,
    this.value,
    this.options,
  });
}

class TransportRegistrationForm {
  final bool isRegistered;
  final String? instructions;
  final String? oobUrl;
  final String? formType; // e.g., 'urn:xmpp:slidge:telegram'
  final List<FormField> fields;

  TransportRegistrationForm({
    required this.isRegistered,
    this.instructions,
    this.oobUrl,
    this.formType,
    this.fields = const [],
  });

  /// True when the form has no fillable (non-hidden) fields — e.g. slidge's
  /// WhatsApp form, which only carries instructions: submitting it empty
  /// starts the pairing session and the QR arrives as a message afterwards.
  bool get isEmptyForm => !fields.any((f) => f.type != 'hidden' && f.type != 'fixed');

  String? get titleText {
    for (final hint in ['WhatsApp', 'Telegram', 'Discord', 'Matrix', 'IRC']) {
      if (instructions?.contains(hint) ?? false) return hint;
    }
    return null;
  }
}

/// Result of a XEP-0077 registration submit against a gateway.
class GatewaySubmitResult {
  final bool success;
  /// When the gateway answers with another form (multi-step flows, e.g. a
  /// Telegram code entry), this holds the next form to render.
  final TransportRegistrationForm? nextForm;
  final String? errorText;

  const GatewaySubmitResult({
    required this.success,
    this.nextForm,
    this.errorText,
  });
}

/// A chat/channel exposed by a gateway component (guild channel for Discord,
/// group chats for Telegram, etc.), discovered via disco#items.
class GatewayChatItem {
  final String jid;
  final String name;

  const GatewayChatItem({required this.jid, required this.name});
}

/// Live events streamed while a legacy pairing (WhatsApp QR, code entry...)
/// is in progress.
class GatewayPairingEvent {
  /// 'qr' | 'text' | 'success' | 'error'
  final String kind;
  final String gatewayJid;
  /// For 'qr': a URL of the QR image (from XEP-0066 oob data).
  final String? oobUrl;
  /// For 'text': a human-readable status/instruction line.
  final String? text;
  /// For multi-step flows: the next form to render.
  final TransportRegistrationForm? form;

  const GatewayPairingEvent({
    required this.kind,
    required this.gatewayJid,
    this.oobUrl,
    this.text,
    this.form,
  });

  bool get isQr => kind == 'qr';
  bool get isSuccess => kind == 'success';
  bool get isError => kind == 'error';
}
