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
}
