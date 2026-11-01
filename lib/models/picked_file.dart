import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'chat_models.dart';

class PickedFile {
  final String name;
  final Uint8List bytes;
  final int size;
  final String? path;
  final String contentType;

  const PickedFile({
    required this.name,
    required this.bytes,
    required this.size,
    this.path,
    required this.contentType,
  });

  static final _mimeMap = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'bmp': 'image/bmp',
    'svg': 'image/svg+xml',
    'tiff': 'image/tiff',
    'tif': 'image/tiff',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'flac': 'audio/flac',
    'aac': 'audio/aac',
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt': 'text/plain',
    'csv': 'text/csv',
    'json': 'application/json',
    'xml': 'application/xml',
    'zip': 'application/zip',
    'rar': 'application/vnd.rar',
    '7z': 'application/x-7z-compressed',
    'tar': 'application/x-tar',
    'gz': 'application/gzip',
    'apk': 'application/vnd.android.package-archive',
  };

  static final _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'svg', 'tiff', 'tif',
  };

  static String detectMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return _mimeMap[ext] ?? 'application/octet-stream';
  }

  static bool isImage(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return _imageExtensions.contains(ext);
  }

  static String _extFromUrl(String url) {
    try {
      final path = Uri.parse(url).path;
      final lastSegment = path.split('/').last;
      final dotIndex = lastSegment.lastIndexOf('.');
      if (dotIndex > 0) return lastSegment.substring(dotIndex + 1).toLowerCase();
    } catch (_) {}
    return '';
  }

  static bool isImageUrl(String url) => isImage(_extFromUrl(url));

  static bool isFileUrl(String url) {
    final ext = _extFromUrl(url);
    if (ext.isEmpty) return false;
    return _mimeMap.containsKey(ext);
  }

  static String fileNameFromUrl(String url) {
    try {
      final path = Uri.parse(url).path;
      final lastSegment = path.split('/').last;
      if (lastSegment.isNotEmpty) return Uri.decodeFull(lastSegment);
    } catch (_) {}
    return 'file';
  }

  static MessageType classifyFromUrl(String url) {
    return isImageUrl(url) ? MessageType.image : MessageType.file;
  }

  /// On the web, any XMPP-provided upload URL that resolves to an internal
  /// prosody file-share host/port is rewritten to the same-origin /upload
  /// proxy (the backend forwards to prosody). This keeps QR-code attachments
  /// and gateway avatars fetchable by the browser without mixed-content or
  /// self-signed-certificate problems. Returns [url] unchanged when it is
  /// already same-origin, malformed, or not an upload path.
  static String maybeRewriteUploadUrl(String url) {
    if (!kIsWeb) return url;
    final pathStart = url.indexOf('/upload/');
    if (pathStart == -1) return url;
    final isHttp = url.startsWith('http://') || url.startsWith('https://');
    if (!isHttp) return url;
    // Browsers cannot fetch an internal http:// host from an https page;
    // rewrite to the same-origin proxy path.
    return url.substring(pathStart);
  }
}
