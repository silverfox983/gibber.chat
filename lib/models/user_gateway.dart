class UserGateway {
  final String id;
  final String userId;
  final String gatewayType;
  final Map<String, dynamic> config;
  final bool enabled;
  final String status;
  final String? componentJid;
  final String? containerId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  UserGateway({
    required this.id,
    required this.userId,
    required this.gatewayType,
    required this.config,
    required this.enabled,
    required this.status,
    this.componentJid,
    this.containerId,
    this.createdAt,
    this.updatedAt,
  });

  factory UserGateway.fromJson(Map<String, dynamic> json) => UserGateway(
        id: json['id'],
        userId: json['userId'],
        gatewayType: json['gatewayType'],
        config: Map<String, dynamic>.from(json['config'] ?? {}),
        enabled: json['enabled'] ?? false,
        status: json['status'] ?? 'disabled',
        componentJid: json['componentJid'],
        containerId: json['containerId'],
        createdAt:
            json['createdAt'] != null ? DateTime.parse(json['createdAt']) : null,
        updatedAt:
            json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'gatewayType': gatewayType,
        'config': config,
        'enabled': enabled,
        'status': status,
        'componentJid': componentJid,
        'containerId': containerId,
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  UserGateway copyWith({
    String? id,
    String? userId,
    String? gatewayType,
    Map<String, dynamic>? config,
    bool? enabled,
    String? status,
    String? componentJid,
    String? containerId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      UserGateway(
        id: id ?? this.id,
        userId: userId ?? this.userId,
        gatewayType: gatewayType ?? this.gatewayType,
        config: config ?? this.config,
        enabled: enabled ?? this.enabled,
        status: status ?? this.status,
        componentJid: componentJid ?? this.componentJid,
        containerId: containerId ?? this.containerId,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class GatewayTypeInfo {
  final String type;
  final String name;
  final String description;
  final String icon;
  final List<String> requiredFields;
  final List<String> optionalFields;

  const GatewayTypeInfo({
    required this.type,
    required this.name,
    required this.description,
    required this.icon,
    required this.requiredFields,
    this.optionalFields = const [],
  });

  static const Map<String, GatewayTypeInfo> available = {
    'telegram': GatewayTypeInfo(
      type: 'telegram',
      name: 'Telegram',
      description: 'Bridge to Telegram messenger',
      icon: 'telegram',
      requiredFields: ['api_id', 'api_hash'],
      optionalFields: ['phone_number', 'bot_token'],
    ),
    'discord': GatewayTypeInfo(
      type: 'discord',
      name: 'Discord',
      description: 'Bridge to Discord servers and channels',
      icon: 'discord',
      requiredFields: ['bot_token'],
      optionalFields: ['server_ids'],
    ),
    'irc': GatewayTypeInfo(
      type: 'irc',
      name: 'IRC',
      description: 'Bridge to IRC networks',
      icon: 'irc',
      requiredFields: ['server_hostname', 'server_port'],
      optionalFields: ['nickname', 'channels', 'password'],
    ),
    'matrix': GatewayTypeInfo(
      type: 'matrix',
      name: 'Matrix',
      description: 'Bridge to Matrix homeservers',
      icon: 'matrix',
      requiredFields: ['homeserver_url'],
      optionalFields: ['access_token', 'user_id'],
    ),
    'whatsapp': GatewayTypeInfo(
      type: 'whatsapp',
      name: 'WhatsApp',
      description: 'Bridge to WhatsApp (via linked device)',
      icon: 'whatsapp',
      requiredFields: ['phone_number'],
      optionalFields: ['device_name'],
    ),
  };
}
