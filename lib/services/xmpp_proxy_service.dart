import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const Duration _connectionTimeout = Duration(seconds: 12); 
const Duration _starttlsTimeout = Duration(seconds: 20);

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
          String content = String.fromCharCodes(data);
          bool modified = false;

          // 0. Strip Stream Management to prevent xmpp_stone counting bug
          if (content.contains('urn:xmpp:sm:')) {
            content = content.replaceAll(RegExp('<sm xmlns=[\'"]urn:xmpp:sm:[23][\'"][^>]*/>'), '');
            content = content.replaceAll(RegExp('<sm xmlns=[\'"]urn:xmpp:sm:[23][\'"][^>]*>.*?</sm>', dotAll: true), '');
            modified = true;
          }

          // FEATURE TRANSFORMER: Transform ALL stream:features packets
          // xmpp_stone processes every stream:features it receives, including
          // post-auth features after SASL re-open. We must transform them all.
          if (content.contains('<stream:features')) {
             debugPrint('Proxy: Intercepted server features. Performing compatibility transformation...');
             
             // 1. Strip STARTTLS (Offloaded to Proxy - we already handle TLS)
             content = content.replaceAll(RegExp(r'<starttls[^>]*>.*?</starttls>', dotAll: true), '');
             content = content.replaceAll(RegExp(r'<starttls[^>]*/>'), '');

             // 2. Remove SASL2 inline features that xmpp_stone doesn't support
             content = content.replaceAll(RegExp(r'<inline[^>]*>.*?</inline>', dotAll: true), '');
             
             // 3. Remove SASL2 <authentication> block (xmpp_stone only supports SASL1)
             if (content.contains(RegExp('<authentication xmlns=[\'"]urn:xmpp:sasl:2[\'"]', dotAll: true))) {
               final sasl2Mechs = RegExp(r'<mechanism>([^<]+)</mechanism>')
                   .allMatches(content)
                   .map((m) => m.group(1)!)
                   .toSet();
               
               content = content.replaceAll(RegExp('<authentication xmlns=[\'"]urn:xmpp:sasl:2[\'"][^>]*>.*?</authentication>', dotAll: true), '');
               
               if (!content.contains('<mechanisms')) {
                 final mechs = sasl2Mechs.toList()..add('PLAIN');
                 final mechsXml = mechs.map((m) => '<mechanism>$m</mechanism>').join('');
                 final legacySasl = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>$mechsXml</mechanisms>";
                 content = content.replaceFirst('<stream:features>', '<stream:features>$legacySasl');
               }
             }
             
             // 4. Ensure PLAIN mechanism is available for xmpp_stone SASL1 auth
             if (content.contains('<mechanisms') && !content.contains('<mechanism>PLAIN</mechanism>')) {
               content = content.replaceFirst(
                 RegExp("<mechanisms xmlns=['\"]urn:ietf:params:xml:ns:xmpp-sasl['\"]>"),
                 "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism>",
               );
             }
             
              modified = true;
              debugPrint('Proxy: Transformation successful. Preserved server mechanisms, removed SASL2 inline features.');
          }

          if (modified) {
            finalData = Uint8List.fromList(utf8.encode(content));
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
    final targets = <String>{host, 'xmpp.$host', 'chat.$host'};
    
    // 1. SRV Discovery via DoH
    try {
      final url = 'https://dns.google/resolve?name=_xmpp-client._tcp.$host&type=SRV';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['Answer'] != null) {
          for (var answer in data['Answer']) {
             final srv = answer['data'] as String;
             final parts = srv.split(' ');
             if (parts.length >= 4) {
               targets.add(parts[3].replaceAll(RegExp(r'\.$'), ''));
             }
          }
        }
      }
    } catch (_) {}

    debugPrint('Proxy: Starting Parallel Happy-Eyeballs probe on: $targets');
    
    final completer = Completer<Socket>();
    int totalAttempts = 0;
    int failedCount = 0;
    final pendingFutures = <Future>[];

    void reportFailure(String target, int port, dynamic error) {
      debugPrint('Proxy: [Probe Failure] $target:$port -> $error');
      failedCount++;
      if (failedCount >= totalAttempts && !completer.isCompleted) {
        completer.completeError('All connection paths to $host failed. Last error: $error');
      }
    }

    for (String target in targets) {
      debugPrint('Proxy: [Probe Queue] $target (Paths: 5222, 5223, 443)');
      
      // Path A: STARTTLS (5222) - HIGH PRIORITY
      totalAttempts++;
      final futureA = _tryConnectAndHandshakeAsync(target, 5222, initialPacket).then((s) {
        if (!completer.isCompleted) {
          debugPrint('Proxy: [Probe Winner] $target:5222 (STARTTLS)');
          completer.complete(s);
        } else {
          s.destroy();
        }
      }).catchError((e) {
        debugPrint('Proxy: [Probe Fail Trace] $target:5222 -> $e');
        reportFailure(target, 5222, e);
      });
      pendingFutures.add(futureA);

      // Path B: Direct TLS (5223)
      totalAttempts++;
      final futureB = Future.delayed(const Duration(milliseconds: 100)).then((_) {
        return _tryDirectTLSAsync(target, 5223, initialPacket).then((s) {
          if (!completer.isCompleted) {
             debugPrint('Proxy: [Probe Winner] $target:5223 (Direct TLS)');
             completer.complete(s);
          } else {
            s.destroy();
          }
        }).catchError((e) {
          debugPrint('Proxy: [Probe Fail Trace] $target:5223 -> $e');
          reportFailure(target, 5223, e);
        });
      });
      pendingFutures.add(futureB);

      // Path C: Direct TLS (443)
      totalAttempts++;
      final futureC = Future.delayed(const Duration(milliseconds: 300)).then((_) {
        return _tryDirectTLSAsync(target, 443, initialPacket).then((s) {
          if (!completer.isCompleted) {
            debugPrint('Proxy: [Probe Winner] $target:443 (Direct TLS)');
            completer.complete(s);
          } else {
            s.destroy();
          }
        }).catchError((e) {
          debugPrint('Proxy: [Probe Fail Trace] $target:443 -> $e');
          reportFailure(target, 443, e);
        });
      });
      pendingFutures.add(futureC);
    }

    // Wait for all probes to finish before declaring total failure
    // This prevents premature completeError when staggered probes haven't started yet
    Future.wait(pendingFutures).catchError((_) {});

    return await completer.future.timeout(const Duration(seconds: 45));
  }

  Future<Socket> _tryConnectAndHandshakeAsync(String host, int port, Uint8List initialPacket) async {
    final list = await InternetAddress.lookup(host);
    final resolved = list.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => list.first);
    
    final rawSocket = await RawSocket.connect(resolved, port).timeout(_connectionTimeout);
    
    // Some servers are extremely sensitive to the exact attribute order in the header.
    // We use the same battle-tested header that worked in our standalone test.
    final cleanTag = "<stream:stream to='$host' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>\n";
    
    // Attach listener FIRST to prevent race condition if server responds instantly
    final resultFuture = _pollRawUntil(rawSocket, ['<starttls', '</stream:features>']);
    print('!!! PROXY_DIAG: [Probe Write] $resolved:$port (Packet Size: ${initialPacket.length}) -> $cleanTag');
    rawSocket.write(utf8.encode(cleanTag));
    final result = await resultFuture;
    
    if (result.matchedMarker == '<starttls') {
      // Step 2: Immediate STARTTLS request as soon as marker is seen (matching test_tls.dart)
      final startTlsTag = '<starttls xmlns="urn:ietf:params:xml:ns:xmpp-tls"/>';
      final written = rawSocket.write(utf8.encode(startTlsTag));
      print('!!! PROXY_DIAG: [Probe Write] Sending STARTTLS ($written bytes) -> $startTlsTag');
      
      final r3 = await _pollRawUntil(rawSocket, ['<proceed'], existingSub: result.sub, initialData: result.accumulated);
      print('!!! PROXY_DIAG: Handshake proceed marker reached.');
      
      final r4 = await _pollRawUntil(rawSocket, ['>'], existingSub: r3.sub, initialData: r3.accumulated);
      print('!!! PROXY_DIAG: Handshake proceed tag end reached.');
      
      r4.sub?.onData(null);
      r4.sub?.resume();
      print('!!! PROXY_DIAG: Finalizing TLS upgrade with resumed subscription.');
      final rawSecure = await RawSecureSocket.secure(rawSocket, subscription: r4.sub as StreamSubscription<RawSocketEvent>?, onBadCertificate: (cert) => true).timeout(_connectionTimeout);
      
      // FINAL VALIDATION: Ensure the tunnel actually speaks XMPP
      final secureResultFuture = _pollRawUntil(rawSecure, ['<stream:stream']);
      rawSecure.write(utf8.encode(cleanTag));
      final secureResult = await secureResultFuture;

      return RawToSocket(rawSecure, secureResult.accumulated, secureResult.sub as StreamSubscription<RawSocketEvent>?);
    } else {
      debugPrint('Proxy: Server does NOT offer STARTTLS. Falling back to unencrypted bridge.');
      return RawToSocket(rawSocket, result.accumulated, result.sub as StreamSubscription<RawSocketEvent>?);
    }
  }

  Future<Socket> _tryDirectTLSAsync(String host, int port, Uint8List initialPacket) async {
    final list = await InternetAddress.lookup(host);
    final resolved = list.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => list.first);
    
    final rawSocket = await RawSocket.connect(resolved, port).timeout(_connectionTimeout);
    final rawSecure = await RawSecureSocket.secure(rawSocket, onBadCertificate: (cert) => true).timeout(_connectionTimeout);
    
    // FINAL VALIDATION: Ensure it's not a Web Server
    String rawTag = String.fromCharCodes(initialPacket);
    String cleanTag = rawTag.replaceAll(RegExp(r'<\?xml[^?]*\?>'), '').trim();
    if (!cleanTag.endsWith('>')) {
      int tagEnd = cleanTag.indexOf('>');
      if (tagEnd != -1) cleanTag = cleanTag.substring(0, tagEnd + 1);
    }
    
    final resultFuture = _pollRawUntil(rawSecure, ['<stream:stream']);
    rawSecure.write(utf8.encode(cleanTag));
    final result = await resultFuture;

    return RawToSocket(rawSecure, result.accumulated, result.sub as StreamSubscription<RawSocketEvent>?);
  }

  Future<_PollResult> _pollRawUntil(dynamic socket, List<String> markers, {StreamSubscription? existingSub, String initialData = ""}) async {
    final completer = Completer<_PollResult>();
    String accumulated = initialData;
    StreamSubscription? sub = existingSub;

    bool checkMarkers() {
      for (final marker in markers) {
         if (accumulated.contains(marker)) {
            if (existingSub == null) sub?.pause();
            if (!completer.isCompleted) completer.complete(_PollResult(accumulated, marker, sub));
            return true;
         }
      }
      if (accumulated.contains('HTTP/1.') || accumulated.contains('<html>')) {
         sub?.cancel();
         if (!completer.isCompleted) completer.completeError('Detected Web Server instead of XMPP');
         return true;
      }
      if (accumulated.contains('<failure') || accumulated.contains('<error')) {
         sub?.cancel();
         if (!completer.isCompleted) completer.completeError('XMPP Error');
         return true;
      }
      return false;
    }

    // 1. Immediate check for data already in the accumulator
    if (checkMarkers()) {
      return completer.future;
    }

    void onData(dynamic event) {
      print('!!! PROXY_DIAG: [onData Event] $event');
      if (event == RawSocketEvent.read) {
        Uint8List? bytes;
        while ((bytes = socket.read()) != null) {
          final chunk = utf8.decode(bytes!, allowMalformed: true);
          accumulated += chunk;
          print('!!! PROXY_DIAG: [Probe Read] Accumulated ${accumulated.length} bytes. Last chunk: $chunk');
          if (checkMarkers()) return;
        }
      } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
         sub?.cancel();
         if (!completer.isCompleted) completer.completeError('Socket closed unexpectedly');
      }
    }

    void onError(e) {
      sub?.cancel();
      if (!completer.isCompleted) completer.completeError(e);
    }

    void onDone() {
      sub?.cancel();
      if (!completer.isCompleted) completer.completeError('Socket closed unexpectedly');
    }

    if (sub == null) {
       sub = socket.listen(onData, onError: onError, onDone: onDone);
    } else {
       sub.onData(onData);
       sub.onError(onError);
       sub.onDone(onDone);
       sub.resume();
    }

    final timer = Timer(_starttlsTimeout, () {
      sub?.cancel();
      if (!completer.isCompleted) completer.completeError('Timeout');
    });

    return await completer.future.whenComplete(() {
      timer.cancel();
    });
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

class _PollResult {
  final String accumulated;
  final String matchedMarker;
  final StreamSubscription? sub;
  _PollResult(this.accumulated, this.matchedMarker, this.sub);
}

class RawToSocket extends StreamView<Uint8List> implements Socket {
  final RawSocket _inner;
  final List<int> _writeBuffer = [];
  final StreamController<Uint8List> _controller;

  RawToSocket._(this._inner, this._controller, [String? initialData, StreamSubscription<RawSocketEvent>? existingSub]) : super(_controller.stream) {
    if (initialData != null && initialData.isNotEmpty) {
      Future.microtask(() {
        if (!_controller.isClosed) {
          _controller.add(Uint8List.fromList(utf8.encode(initialData)));
        }
      });
    }
    
    void handleEvent(event) {
      if (event == RawSocketEvent.read) {
        Uint8List? data;
        while ((data = _inner.read()) != null) {
          if (!_controller.isClosed) _controller.add(data!);
        }
      } else if (event == RawSocketEvent.write) {
        _tryWrite();
      } else if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) {
        if (!_controller.isClosed) _controller.close();
      }
    }

    if (existingSub != null) {
      existingSub.onData(handleEvent);
      existingSub.onError((e) => _controller.addError(e));
      existingSub.onDone(() => _controller.close());
      existingSub.resume();
    } else {
      _inner.listen(handleEvent, onError: (e) => _controller.addError(e), onDone: () => _controller.close());
    }
  }

  factory RawToSocket(RawSocket inner, [String? initialData, StreamSubscription<RawSocketEvent>? existingSub]) {
    return RawToSocket._(inner, StreamController<Uint8List>(), initialData, existingSub);
  }

  void _tryWrite() {
    if (_writeBuffer.isEmpty) return;
    try {
      int written = _inner.write(_writeBuffer);
      if (written > 0) {
        _writeBuffer.removeRange(0, written);
      }
    } catch (e) {
      debugPrint('Proxy: Write error on RawToSocket: $e');
      _controller.addError(e);
    }
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
  
  @override void add(List<int> data) {
    _writeBuffer.addAll(data);
    _tryWrite();
  }
  
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override Future addStream(Stream<List<int>> stream) async => stream.listen((d) => add(d)).asFuture();
  @override Future close() async => _inner.close();
  @override Future get done => Future.delayed(Duration.zero);
  @override Future flush() async {}
  
  @override void write(Object? obj) {
    _writeBuffer.addAll(utf8.encode(obj.toString()));
    _tryWrite();
  }
  
  @override void writeAll(Iterable objects, [String separator = ""]) => write(objects.join(separator));
  @override void writeCharCode(int charCode) {
    _writeBuffer.add(charCode);
    _tryWrite();
  }
  @override void writeln([Object? obj = ""]) => write("${obj ?? ''}\n");
  @override void destroy() => _inner.close();
}
