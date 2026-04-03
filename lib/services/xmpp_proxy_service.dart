import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

const Duration _connectionTimeout = Duration(seconds: 15);
const Duration _starttlsTimeout = Duration(seconds: 25);

/// A secure bridge that adapts its TLS handshake to find the correct path for an XMPP server.
class XmppProxyService {
  ServerSocket? _server;
  int? get port => _server?.port;

  Future<int> start(String remoteHost, int remotePort, String sniDomain) async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    debugPrint(
      'XMPP Proxy: Listening on 127.0.0.1:${_server!.port} -> Secure $remoteHost:$remotePort (SNI: $sniDomain)',
    );

    _server!.listen((clientSocket) async {
      debugPrint('Proxy: Library connected. Probing secure remote link...');
      try {
        final remoteSocket = await _establishSecureLink(
          remoteHost,
          remotePort,
          sniDomain,
        );
        debugPrint('Proxy: Final Secure Remote Link established!');

        // Bridge: Forward plain library data to secure remote
        clientSocket.listen((data) {
          remoteSocket.add(data);
        }, onDone: () => remoteSocket.destroy(), onError: (e) => remoteSocket.destroy());

        // Bridge: Forward secure remote data to plain library
        remoteSocket.listen((data) {
          clientSocket.add(data);
        }, onDone: () => clientSocket.destroy(), onError: (e) => clientSocket.destroy());
      } catch (e) {
        debugPrint('Proxy Fatal Error: $e');
        clientSocket.destroy();
      }
    });

    return _server!.port;
  }

  Future<Socket> _establishSecureLink(String host, int port, String sni) async {
    Exception? lastError;

    // Attempt 1: Port 5223 (Direct TLS) with SNI ($sni)
    try {
      debugPrint('Proxy: [1/5] Trying Direct TLS (5223) + SNI ($sni)...');
      final plain = await Socket.connect(
        host,
        5223,
      ).timeout(_connectionTimeout);
      return await SecureSocket.secure(
        plain,
        host: sni,
        onBadCertificate: (cert) => true,
      ).timeout(_connectionTimeout);
    } catch (e) {
      debugPrint('Proxy: [1/5] Failed: $e');
      lastError = Exception('Direct TLS with SNI failed: $e');
    }

    // Attempt 2: Port 5223 (Direct TLS) WITHOUT SNI
    try {
      debugPrint('Proxy: [2/5] Trying Direct TLS (5223) NO SNI...');
      return await SecureSocket.connect(
        host,
        5223,
        onBadCertificate: (cert) => true,
      ).timeout(_connectionTimeout);
    } catch (e) {
      debugPrint('Proxy: [2/5] Failed: $e');
      lastError = Exception('Direct TLS without SNI failed: $e');
    }

    // Attempt 3: Port 5222 (STARTTLS) with SNI ($sni)
    try {
      debugPrint('Proxy: [3/5] Trying STARTTLS (5222) + SNI ($sni)...');
      final socket = await Socket.connect(
        host,
        5222,
      ).timeout(_connectionTimeout);
      socket.write(
        "<?xml version='1.0'?><stream:stream to='$sni' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>",
      );

      final completer = Completer<Socket>();
      String buffer = '';
      StreamSubscription? sub;
      sub = socket.listen((data) async {
        final chunk = String.fromCharCodes(data);
        buffer += chunk;
        debugPrint('Proxy [3/5]: Srv sent chunk (${chunk.length} bytes)');

        if (buffer.contains('<starttls') && !buffer.contains('<proceed')) {
          socket.write("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
          buffer = ''; 
        } else if (buffer.contains('<proceed')) {
          try {
            await sub?.cancel();
            final secure = await SecureSocket.secure(
              socket,
              host: sni,
              onBadCertificate: (cert) => true,
            );
            completer.complete(secure);
          } catch (e) {
            completer.completeError(e);
          }
        }
      }, onError: (e) => completer.completeError(e), onDone: () => completer.completeError('Socket closed during STARTTLS'));

      try {
        return await completer.future.timeout(_starttlsTimeout);
      } finally {
        await sub?.cancel();
      }
    } catch (e) {
      debugPrint('Proxy: [3/5] Failed: $e');
      lastError = Exception('STARTTLS with SNI failed: $e');
    }

    // Attempt 4: Port 5222 (STARTTLS) WITHOUT SNI
    try {
      debugPrint('Proxy: [4/5] Trying STARTTLS (5222) NO SNI...');
      final socket = await Socket.connect(
        host,
        5222,
      ).timeout(_connectionTimeout);
      socket.write(
        "<?xml version='1.0'?><stream:stream to='$sni' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>",
      );

      final completer = Completer<Socket>();
      String buffer = '';
      StreamSubscription? sub;
      sub = socket.listen((data) async {
        final chunk = String.fromCharCodes(data);
        buffer += chunk;
        if (buffer.contains('<starttls') && !buffer.contains('<proceed')) {
          socket.write("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
          buffer = '';
        } else if (buffer.contains('<proceed')) {
          try {
            await sub?.cancel();
            final secure = await SecureSocket.secure(
              socket,
              onBadCertificate: (cert) => true,
            );
            completer.complete(secure);
          } catch (e) {
            completer.completeError(e);
          }
        }
      }, onError: (e) => completer.completeError(e), onDone: () => completer.completeError('Socket closed during STARTTLS (No SNI)'));

      try {
        return await completer.future.timeout(_starttlsTimeout);
      } finally {
        await sub?.cancel();
      }
    } catch (e) {
      debugPrint('Proxy: [4/5] Failed: $e');
      lastError = Exception('STARTTLS without SNI failed: $e');
    }

    // Attempt 5: Plain Fallback (Port 5222)
    try {
      debugPrint('Proxy: [5/5] Trying PLAIN Fallback (5222)...');
      return await Socket.connect(
        host,
        5222,
      ).timeout(_connectionTimeout);
    } catch (e) {
      debugPrint('Proxy: [5/5] Failed: $e');
      lastError = Exception('Plain fallback failed: $e');
    }

    throw lastError ??
        Exception('Adaptive Probe Failed: All 5 connection paths exhausted.');
  }

  void stop() {
    _server?.close();
    _server = null;
  }
}
