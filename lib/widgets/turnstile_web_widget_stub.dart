import 'package:flutter/material.dart';

class TurnstileWebWidget extends StatelessWidget {
  final String siteKey;
  final String theme;
  final String action;
  final ValueChanged<String>? onTokenReceived;
  final VoidCallback? onTokenExpired;
  final VoidCallback? onError;

  const TurnstileWebWidget({
    super.key,
    required this.siteKey,
    this.theme = 'light',
    this.action = 'signup',
    this.onTokenReceived,
    this.onTokenExpired,
    this.onError,
  });

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}