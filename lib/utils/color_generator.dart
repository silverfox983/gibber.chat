import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

class ColorGenerator {
  /// Implementation of XEP-0392: Consistent Color Generation.
  /// Generates a deterministic color for a given JID or string.
  static Color getColorForId(String id) {
    // 1. Hash the JID (bare JID recommended)
    final bareId = id.split('/').first.toLowerCase();
    final bytes = utf8.encode(bareId);
    final hash = sha1.convert(bytes).bytes;

    // 2. Use the first 2 bytes to determine Hue
    // We want to avoid very light or very dark colors for readability
    final int hVal = (hash[0] << 8) | hash[1];
    final double hue = (hVal % 360).toDouble();

    // 3. XEP-0392 suggests specific saturation/lightness for different themes
    // For Gibber, we use a vibrant but balanced range.
    return HSLColor.fromAHSL(1.0, hue, 0.6, 0.6).toColor();
  }
}
