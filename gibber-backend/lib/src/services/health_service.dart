import 'dart:io';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/xmpp_registrar.dart';

class HealthService {
  final DatabaseService db;
  final XmppRegistrar xmppRegistrar;

  HealthService({required this.db, required this.xmppRegistrar});

  Future<Map<String, dynamic>> checkHealth() async {
    final results = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'domain': xmppRegistrar.domain,
    };

    // Database check
    try {
      final rows = db.db.select('SELECT COUNT(*) as count FROM users');
      results['database'] = {
        'status': 'healthy',
        'userCount': rows.first['count'],
      };
    } catch (e) {
      results['database'] = {
        'status': 'unhealthy',
        'error': e.toString(),
      };
    }

    // Prosody connectivity check
    final prosodyUri = Uri.parse(xmppRegistrar.prosodyHttpUrl);
    final wsScheme = prosodyUri.scheme == 'https' ? 'wss' : 'ws';
    final wsPort = prosodyUri.port > 0 ? prosodyUri.port : (prosodyUri.scheme == 'https' ? 5281 : 5280);
    final wsUrl = '$wsScheme://${prosodyUri.host}:$wsPort/xmpp-websocket';

    bool prosodyHealthy = false;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse('${xmppRegistrar.prosodyHttpUrl}/xmpp-websocket'));
      final response = await request.close();
      prosodyHealthy = response.statusCode == 200 || response.statusCode == 404 || response.statusCode == 400;
      client.close();
    } catch (e) {
      prosodyHealthy = false;
    }

    results['prosody'] = {
      'status': prosodyHealthy ? 'healthy' : 'unhealthy',
      'url': xmppRegistrar.prosodyHttpUrl,
      'websocketUrl': wsUrl,
    };

    // Janus connectivity check
    bool janusHealthy = false;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse('http://localhost:8088/janus/info'));
      final response = await request.close();
      janusHealthy = response.statusCode == 200;
      client.close();
    } catch (e) {
      janusHealthy = false;
    }

    results['janus'] = {
      'status': janusHealthy ? 'healthy' : 'unhealthy',
      'url': 'ws://localhost:8188/',
    };

    // coturn connectivity check
    bool coturnHealthy = false;
    try {
      // TURN server responds to a UDP STUN binding request on port 3478
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.listen((e) {
        if (e == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg != null) {
            coturnHealthy = true;
          }
        }
      });
      // STUN binding request header (magic cookie + transaction ID)
      final stunReq = [
        0x00, 0x01, 0x00, 0x00, // Binding Request, 0 bytes attrs
        0x21, 0x12, 0xa4, 0x42, // Magic cookie
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ];
      final addr = InternetAddress.tryParse('127.0.0.1');
      if (addr != null) {
        socket.send(stunReq, addr, 3478);
      }
      await Future.delayed(const Duration(seconds: 2));
      socket.close();
    } catch (e) {
      coturnHealthy = false;
    }

    results['coturn'] = {
      'status': coturnHealthy ? 'healthy' : 'unhealthy',
      'host': 'localhost',
      'port': 3478,
    };

    final dbHealthy = (results['database'] as Map<String, dynamic>)['status'] == 'healthy';
    final overallStatus = dbHealthy ? 'healthy' : 'degraded';

    return {
      'status': overallStatus,
      ...results,
    };
  }
}