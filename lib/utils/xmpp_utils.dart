import 'dart:convert';
import 'package:crypto/crypto.dart';

class XmppUtils {
  /// Calculates XEP-0115: Entity Capabilities 'ver' hash (legacy/SHA-1 version)
  static String calculateCapsHash(
    List<String> features, {
    String category = 'client',
    String type = 'pc',
    String name = 'Gibber',
  }) {
    // 1. Initialize S
    final List<String> identityStrings = [
      '$category/$type//$name<',
    ];
    
    // 2. Sort identities (we only have one here, but we should sort if we had more)
    identityStrings.sort();
    
    // 3. Sort features
    final sortedFeatures = List<String>.from(features)..sort();
    final List<String> featureStrings = sortedFeatures.map((f) => '$f<').toList();
    
    // 4. Concatenate
    final String s = identityStrings.join() + featureStrings.join();
    
    // 5. SHA-1 and Base64
    final bytes = utf8.encode(s);
    final digest = sha1.convert(bytes);
    return base64.encode(digest.bytes);
  }

  /// Converts basic Markdown to XHTML-IM (XEP-0071) format
  static String convertMarkdownToXhtml(String text) {
    String html = text;
    // Escape XML special characters
    html = html.replaceAll('&', '&amp;');
    html = html.replaceAll('<', '&lt;');
    html = html.replaceAll('>', '&gt;');

    // Bold: **text**
    html = html.replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => '<strong>${m[1]}</strong>');
    
    // Italic: _text_
    html = html.replaceAllMapped(RegExp(r'_(.*?)_'), (m) => '<em>${m[1]}</em>');
    
    // Code: `text`
    html = html.replaceAllMapped(RegExp(r'`(.*?)`'), (m) => '<code>${m[1]}</code>');
    
    // Newlines
    html = html.replaceAll('\n', '<br/>');

    return '<html xmlns="http://jabber.org/protocol/xhtml-im"><body xmlns="http://www.w3.org/1999/xhtml"><p>$html</p></body></html>';
  }

  /// Extremely naive extraction of text from XHTML for display in simple text fields
  /// (Gibber uses flutter_markdown for actual rendering, so we just want to convert
  /// <html> payloads back to Markdown if possible, or strip tags).
  static String? extractXhtmlToMarkdown(String xhtml) {
    if (!xhtml.contains('xmlns="http://jabber.org/protocol/xhtml-im"')) return null;

    // Extract body content
    final bodyMatch = RegExp(r'<body[^>]*>(.*?)</body>', dotAll: true).firstMatch(xhtml);
    if (bodyMatch == null) return null;
    
    String markdown = bodyMatch.group(1)!;
    
    // Convert basic tags back to markdown
    markdown = markdown.replaceAllMapped(RegExp(r'<strong[^>]*>(.*?)</strong>'), (m) => '**${m[1]}**');
    markdown = markdown.replaceAllMapped(RegExp(r'<em[^>]*>(.*?)</em>'), (m) => '_${m[1]}_');
    markdown = markdown.replaceAllMapped(RegExp(r'<code[^>]*>(.*?)</code>'), (m) => '`${m[1]}`');
    markdown = markdown.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    markdown = markdown.replaceAll(RegExp(r'<p[^>]*>'), '');
    markdown = markdown.replaceAll('</p>', '\n');
    
    // Strip remaining tags
    markdown = markdown.replaceAll(RegExp(r'<[^>]*>'), '');

    // Unescape XML
    markdown = markdown.replaceAll('&lt;', '<');
    markdown = markdown.replaceAll('&gt;', '>');
    markdown = markdown.replaceAll('&amp;', '&');
    
    return markdown.trim();
  }
}
