import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
// ignore: implementation_imports
import 'package:xmpp_stone/src/elements/XmppAttribute.dart';
import 'dart:io' if (dart.library.html) 'file_stub.dart';

class HttpUploadService {
  final xmpp.Connection connection;
  final StreamController<double> _uploadProgressController = StreamController<double>.broadcast();
  Stream<double> get uploadProgress => _uploadProgressController.stream;

  String? uploadServiceJid;
  HttpUploadService(this.connection, {this.uploadServiceJid});

  /// Requests an upload slot from the XMPP server (XEP-0363)
  Future<Map<String, String>?> requestUploadSlot(String fileName, int size, {
    String contentType = 'application/octet-stream',
    bool isRetry = false,
    String? manualJid,
  }) async {
    final completer = Completer<Map<String, String>?>();
    final iqId = 'upload_${DateTime.now().millisecondsSinceEpoch}';

    // XEP-0363: Use manual JID (from fallback), discovered JID, or fallback to assumption
    final targetJid = manualJid ?? uploadServiceJid ?? 'upload.${connection.fullJid.domain}';

    final iq = xmpp.IqStanza(iqId, xmpp.IqStanzaType.GET);
    iq.toJid = xmpp.Jid.fromFullJid(targetJid);

    final request = xmpp.XmppElement();
    request.name = 'request';
    request.addAttribute(XmppAttribute('xmlns', 'urn:xmpp:http:upload:0'));
    request.addAttribute(XmppAttribute('filename', fileName));
    request.addAttribute(XmppAttribute('size', size.toString()));
    request.addAttribute(XmppAttribute('content-type', contentType));
    iq.addChild(request);

    final sub = connection.inStanzasStream.listen((stanza) {
      if (stanza is xmpp.IqStanza && stanza.id == iqId) {
        if (stanza.type == xmpp.IqStanzaType.RESULT) {
          final slot = stanza.getChild('slot');
          if (slot != null && slot.getAttribute('xmlns')?.value == 'urn:xmpp:http:upload:0') {
            final putUrl = slot.getChild('put')?.getAttribute('url')?.value;
            final getUrl = slot.getChild('get')?.getAttribute('url')?.value;
            if (putUrl != null && getUrl != null) {
              completer.complete({'put': putUrl, 'get': getUrl});
            } else {
              completer.complete(null);
            }
          } else {
            completer.complete(null);
          }
        } else {
          completer.complete(null);
        }
      }
    });

    connection.writeStanza(iq);
    
    // Timeout handling
    Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final result = await completer.future;
    sub.cancel();

    // Fallback logic: If it failed and we haven't tried the 'upload.domain' yet
    if (result == null && !isRetry && targetJid == connection.fullJid.domain) {
      final fallbackJid = 'upload.${connection.fullJid.domain}';
      debugPrint('XEP-0363: Request to main domain failed, attempting fallback to: $fallbackJid');
      return await requestUploadSlot(fileName, size, contentType: contentType, isRetry: true, manualJid: fallbackJid);
    }
    
    return result;
  }

  /// Performs the actual HTTP PUT upload with progress tracking (native only)
  /// On web, use [uploadBytes] instead.
  Future<bool> uploadFile(String putUrl, dynamic file, String contentType) async {
    if (kIsWeb) {
      debugPrint('HTTP Upload: uploadFile not supported on web, use uploadBytes instead');
      return false;
    }
    try {
      // ignore: avoid_dynamic_calls
      final nativeFile = file as File;
      final length = await nativeFile.length();
      final stream = nativeFile.openRead();
      final uri = Uri.parse(putUrl);
      
      final request = http.StreamedRequest('PUT', uri);
      request.headers['Content-Type'] = contentType;
      request.headers['Content-Length'] = length.toString();
      
      int bytesUploaded = 0;
      _uploadProgressController.add(0.0);
      
      final Stream<List<int>> progressStream = stream.transform(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            bytesUploaded += data.length;
            final progress = bytesUploaded / length;
            _uploadProgressController.add(progress);
            sink.add(data);
          },
          handleError: (error, stackTrace, sink) {
            debugPrint('Upload Stream Error: $error');
            sink.addError(error, stackTrace);
          },
          handleDone: (sink) {
            sink.close();
          },
        ),
      );

      // Connect the progress stream to the request
      progressStream.listen(
        (data) => request.sink.add(data),
        onDone: () => request.sink.close(),
        onError: (e) => request.sink.addError(e),
        cancelOnError: true,
      );

      final response = await http.Response.fromStream(await request.send());

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _uploadProgressController.add(1.0);
        return true;
      } else {
        debugPrint('HTTP Upload Error: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('HTTP Upload Catch Error: $e');
      _uploadProgressController.add(0.0);
      return false;
    }
  }

  /// Upload raw bytes (web-compatible)
  Future<bool> uploadBytes(String putUrl, Uint8List bytes, String contentType, {int totalSize = -1}) async {
    try {
      final effectiveSize = totalSize > 0 ? totalSize : bytes.length;
      final uri = Uri.parse(putUrl);

      _uploadProgressController.add(0.0);

      final response = await http.put(
        uri,
        headers: {
          'Content-Type': contentType,
          'Content-Length': effectiveSize.toString(),
        },
        body: bytes,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _uploadProgressController.add(1.0);
        return true;
      } else {
        debugPrint('HTTP Upload Error: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('HTTP Upload Catch Error: $e');
      _uploadProgressController.add(0.0);
      return false;
    }
  }

  void dispose() {
    _uploadProgressController.close();
  }
}
