import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/chat_models.dart';
import 'auth_service_deps.dart';
import 'http_upload_service.dart';

class XmppUploadService {
  final AuthServiceUploadDeps _d;

  XmppUploadService(this._d);

  Stream<double>? getUploadProgress(String? accountId) {
    if (accountId == null) return null;
    return _d.uploadServices[accountId]?.uploadProgress;
  }

  Future<void> sendFile(
    String accountId,
    String toJid,
    File file, {
    MessageType type = MessageType.image,
  }) async {
    final conn = _d.xmppConnections[accountId];
    final uploadService = _d.uploadServices[accountId];
    if (conn == null || uploadService == null) {
      throw Exception('Upload service not available for this account.');
    }

    final fileName = file.path.split(RegExp(r'[/\\]')).last;
    final size = await file.length();
    final contentType = type == MessageType.image
        ? 'image/jpeg'
        : 'application/octet-stream';

    debugPrint('XEP-0363: Requesting slot for $fileName ($size bytes)...');
    final slot = await uploadService.requestUploadSlot(
      fileName,
      size,
      contentType: contentType,
    );

    if (slot == null) {
      throw Exception(
        'Server rejected file upload request. (Slot request failed)',
      );
    }

    final putUrl = slot['put']!;
    final getUrl = slot['get']!;

    debugPrint('XEP-0363: Uploading to $putUrl...');
    final success = await uploadService.uploadFile(putUrl, file, contentType);

    if (!success) {
      throw Exception('Failed to upload file to the server.');
    }

    debugPrint('XEP-0363: Upload success. Sending URL to $toJid');

    await _d.sendMessage(
      accountId,
      toJid,
      getUrl,
      type: type,
      fileName: fileName,
      filePath: file.path,
    );
  }

  Future<void> sendMediaMessage(
    String toJid,
    File file,
    MessageType type, {
    String? accountId,
    bool isGroup = false,
    String? caption,
  }) async {
    final id = accountId ?? _d.activeAccountId;
    if (id == null) return;

    if (_d.xmppConnections.containsKey(id)) {
      await sendFile(id, toJid, file, type: type);
    }
  }
}