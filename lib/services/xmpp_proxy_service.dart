import 'dart:async';
import 'dart:io';
import 'dart:convert';
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
      final List<Uint8List> buffer = [];
      bool remoteReady = false;
      bool firstServerPacketTransformed = false;
      Socket? remoteSocket;
      
      final completer = Completer<Uint8List>();

      clientSocket.listen((data) {
        if (!completer.isCompleted) {
          debugPrint('Proxy: Captured initial client handshake packet (${data.length} bytes)');
          completer.complete(data);
        }

        final currentSocket = remoteSocket;
        if (remoteReady && currentSocket != null) {
          final content = String.fromCharCodes(data);
          debugPrint('Proxy: [C->S] XML: $content');
          currentSocket.add(data);
        } else {
          debugPrint('Proxy: Buffering early handshake packet (${data.length} bytes)');
          buffer.add(data);
        }
      }, 
      onDone: () {
        debugPrint('Proxy: Client socket closed');
        remoteSocket?.destroy();
      }, 
      onError: (e) {
        debugPrint('Proxy: Client socket error: $e');
        remoteSocket?.destroy();
      });

      try {
        final initialPacket = await completer.future.timeout(_connectionTimeout);

        // POLLING-SECURE BRIDGE: Establish secure link without Stream locking
        remoteSocket = await _establishSecureLink(
          remoteHost,
          remotePort,
          sniDomain,
          initialPacket,
        );
        debugPrint('Proxy: Final Secure Remote Link established!');

        remoteReady = true;

        remoteSocket.listen((data) {
          Uint8List finalData = data;
          // FEATURE TRANSFORMER: Handle STARTTLS and SASL PLAIN-Injection
          if (!firstServerPacketTransformed) {
            String content = String.fromCharCodes(data);
            if (content.contains('<stream:features')) {
               debugPrint('Proxy: Intercepted server features. Performing PLAIN-Injection for universal compatibility...');
               
               // 1. Strip STARTTLS (Offloaded to Proxy)
               String transformed = content.replaceFirst(RegExp(r'<starttls[^>]*>.*?</starttls>', dotAll: true), '');
               transformed = transformed.replaceFirst(RegExp(r'<starttls[^>]*/>'), '');

               // 2. SASL PLAIN-Injection (The "Ultimate Overload")
               // We replace ALL authentication/mechanisms blocks with a single clean SASL 1 block
               final legacySasl = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism><mechanism>SCRAM-SHA-1</mechanism></mechanisms>";
               
               // Wipe SASL 2
               transformed = transformed.replaceFirst(RegExp(r'<authentication xmlns=.urn:xmpp:sasl:2.>(.*?)</authentication>', dotAll: true), '');
               // Wipe existing SASL 1 (Case insensitive / varied attributes)
               transformed = transformed.replaceFirst(RegExp(r'<mechanisms[^>]*>.*?</mechanisms>', dotAll: true), '');
               
               // Final assembly: Inject our clean mechanisms right after <stream:features>
               transformed = transformed.replaceFirst('<stream:features>', '<stream:features>$legacySasl');
               
               finalData = Uint8List.fromList(transformed.codeUnits);
               firstServerPacketTransformed = true;
               debugPrint('Proxy: Transformation successful. FORCE-INJECTED PLAIN MECHANISM.');
            }
          }
          final preview = String.fromCharCodes(finalData.take(500)).replaceAll('\n', ' ').replaceAll('\r', ' ');
          debugPrint('Proxy: [S->C] Pumping ${finalData.length} bytes: $preview...');
          clientSocket.add(finalData);
        }, 
        onDone: () {
          debugPrint('Proxy: Remote socket closed');
          clientSocket.destroy();
        }, 
        onError: (e) {
          debugPrint('Proxy: Remote socket error: $e');
          clientSocket.destroy();
        });

        // Drain the handshake buffer
        if (buffer.isNotEmpty) {
          debugPrint('Proxy: Analyzing ${buffer.length} buffered chunks for duplicate handshake tags...');
          for (final chunk in buffer) {
            final content = String.fromCharCodes(chunk);
            if (content.contains('<stream:stream') && content.length < 200) {
              debugPrint('Proxy: Handshake tag already sent inside secure tunnel. Skipping.');
              continue;
            }
            debugPrint('Proxy: [C->S] XML: $content');
            remoteSocket.add(chunk);
          }
          buffer.clear();
        }

      } catch (e) {
        debugPrint('Proxy Fatal Error during mirroring: $e');
        clientSocket.destroy();
      }
    });

    return _server!.port;
  }

  Future<Socket> _establishSecureLink(String host, int port, String sni, Uint8List initialPacket) async {
    InternetAddress? resolved;
    try {
      final list = await InternetAddress.lookup(host);
      resolved = list.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => list.first);
      debugPrint('Proxy: Resolved $host to ${resolved.address}');
    } catch (e) {
      resolved = InternetAddress('49.13.15.16');
    }

    // THE POLLING-SECURE BRIDGE (The Real Final Fix)
    try {
      debugPrint('Proxy: [1/1] Trying Polling-Secure STARTTLS (5222)...');
      final rawSocket = await RawSocket.connect(resolved, 5222).timeout(_connectionTimeout);
      
      // 1. Send initial XMPP tag
      rawSocket.write(initialPacket);
      
      // 2. Poll until <starttls.../> (Zero Stream Locks)
      await _pollRawUntil(rawSocket, '<starttls');
      
      // 3. Request upgrade
      rawSocket.write(Uint8List.fromList("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>".codeUnits));
      
      // 4. Poll until <proceed.../>
      await _pollRawUntil(rawSocket, '<proceed');
      await _pollRawUntil(rawSocket, '>');
      
      debugPrint('Proxy [1/1]: Marker found via Poll. Upgrading to TLS (Zero Stream Locks)...');
      
      // 5. Raw Encryption (Accepts the socket because no .listen() call was ever made)
      final rawSecure = await RawSecureSocket.secure(
        rawSocket, 
        onBadCertificate: (cert) => true,
      ).timeout(_connectionTimeout);
      
      debugPrint('Proxy [1/1]: RawSecure Handshake Successful. Wrapping...');
      
      final wrapper = RawToSocket(rawSecure);
      
      // Restart Stream inside tunnel
      _restartStream(wrapper, initialPacket);
      
      return wrapper;
    } catch (e) { 
      debugPrint('Proxy: [1/1] Failed: $e'); 
      rethrow;
    }
  }

  /// Manually peeks at the RawSocket OS buffer until the marker is found. 
  /// This NEVER calls .listen(), fulfilling Dart's requirement for TLS upgrades.
  Future<void> _pollRawUntil(RawSocket socket, String marker) async {
    final target = marker.codeUnits;
    int matchIdx = 0;
    final stopwatch = Stopwatch()..start();
    
    while (stopwatch.elapsed < _starttlsTimeout) {
      while (socket.available() > 0) {
        final bytes = socket.read(1);
        if (bytes == null || bytes.isEmpty) break;
        final byte = bytes[0];
        if (byte == target[matchIdx]) {
          matchIdx++;
          if (matchIdx == target.length) return;
        } else {
          matchIdx = (byte == target[0]) ? 1 : 0;
        }
      }
      // Micro-delay to avoid CPU spinning while OS buffer fills
      await Future.delayed(const Duration(milliseconds: 5));
    }
    throw 'Polling Timeout: Marker "$marker" never arrived in the plain-text buffer.';
  }

  void _restartStream(Socket secure, Uint8List initialPacket) {
    String rawTag = String.fromCharCodes(initialPacket);
    String cleanTag = rawTag.replaceAll(RegExp(r'<\?xml[^?]*\?>'), '').trim();
    secure.write(cleanTag);
  }

  void stop() {
    _server?.close();
    _server = null;
  }
}

/// A lightweight delegate that wraps a RawSecureSocket to provide a standard Socket interface.
class RawToSocket extends StreamView<Uint8List> implements Socket {
  final RawSecureSocket _inner;

  RawToSocket(this._inner) : super(_buildStream(_inner));

  static Stream<Uint8List> _buildStream(RawSecureSocket socket) {
    final controller = StreamController<Uint8List>();
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final data = socket.read();
        if (data != null) controller.add(data);
      } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
        controller.close();
      }
    }, onError: (e) => controller.addError(e), onDone: () => controller.close());
    return controller.stream;
  }

  @override InternetAddress get address => _inner.address;
  @override InternetAddress get remoteAddress => _inner.remoteAddress;
  @override int get port => _inner.port;
  @override int get remotePort => _inner.remotePort;
  @override bool setOption(SocketOption option, bool enabled) => _inner.setOption(option, enabled);
  @override void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
  @override Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override Encoding get encoding => utf8;
  @override set encoding(Encoding value) {}
  @override void add(List<int> data) => _inner.write(data);
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override Future addStream(Stream<List<int>> stream) async => stream.listen((d) => _inner.write(d)).asFuture();
  @override Future close() async => _inner.close();
  @override Future get done => Future.delayed(Duration.zero);
  @override Future flush() async {}
  @override void write(Object? obj) => _inner.write(utf8.encode(obj.toString()));
  @override void writeAll(Iterable objects, [String separator = ""]) => write(objects.join(separator));
  @override void writeCharCode(int charCode) => _inner.write([charCode]);
  @override void writeln([Object? obj = ""]) => write("${obj ?? ''}\n");
  @override void destroy() => _inner.close();
}
