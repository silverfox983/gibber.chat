import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// XEP-0392: Consistent Color Generation
/// Generates deterministic, accessible colors based on XMPP JIDs or identifiers.
class Xep0392Service {
  /// Generates a color for the given identifier (e.g., bare JID or nickname).
  static Color generateColor(String identifier, {bool isDarkTheme = false}) {
    if (identifier.isEmpty) return Colors.grey;

    // 1. Hash the identifier using SHA-1
    final bytes = utf8.encode(identifier);
    final digest = sha1.convert(bytes);

    // 2. Extract the first 2 bytes to form a 16-bit integer (Little Endian)
    final hashBytes = digest.bytes;
    final value = hashBytes[0] | (hashBytes[1] << 8);

    // 3. Map to Hue (0 to 360)
    final hue = (value / 65536.0) * 360.0;

    // 4. Determine Saturation and Lightness
    // Standard XEP-0392 recommends keeping saturation and lightness constrained 
    // to ensure text readability. We adjust slightly based on the app's theme.
    final saturation = isDarkTheme ? 0.65 : 0.75;
    final lightness = isDarkTheme ? 0.65 : 0.45;

    return HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();
  }

  /// Generates a complementary background color (lighter/darker version)
  static Color generateBackgroundColor(String identifier, {bool isDarkTheme = false}) {
    final baseColor = generateColor(identifier, isDarkTheme: isDarkTheme);
    final hsl = HSLColor.fromColor(baseColor);
    
    // Make it much lighter for light themes, or much darker for dark themes
    final newLightness = isDarkTheme 
        ? (hsl.lightness - 0.4).clamp(0.1, 0.9) 
        : (hsl.lightness + 0.4).clamp(0.1, 0.9);
        
    return hsl.withLightness(newLightness).toColor();
  }
}
