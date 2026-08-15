import 'dart:async';
import 'dart:js' as js;
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

class TurnstileWebWidget extends StatefulWidget {
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
  State<TurnstileWebWidget> createState() => _TurnstileWebWidgetState();
}

class _TurnstileWebWidgetState extends State<TurnstileWebWidget> {
  String _viewType = '';

  @override
  void initState() {
    super.initState();
    _setupTurnstile();
  }

  void _setupTurnstile() {
    _viewType = '_turnstile_${DateTime.now().millisecondsSinceEpoch}';

    js.context['_turnstileOnToken$_viewType'] = (String token) {
      widget.onTokenReceived?.call(token);
      if (mounted) setState(() {});
    };

    js.context['_turnstileOnExpired$_viewType'] = () {
      widget.onTokenExpired?.call();
      if (mounted) setState(() {});
    };

    js.context['_turnstileOnError$_viewType'] = () {
      widget.onError?.call();
    };

    final iframe = html.IFrameElement()
      ..width = '300'
      ..height = '65'
      ..style.width = '300px'
      ..style.height = '65px'
      ..style.border = 'none'
      ..style.overflow = 'hidden'
      ..srcdoc = '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"></script>
  <style>
    body { margin: 0; padding: 0; overflow: hidden; background: transparent; }
  </style>
</head>
<body>
  <div id="cf-turnstile"></div>
  <script>
    turnstile.render('#cf-turnstile', {
      sitekey: '${widget.siteKey}',
      action: '${widget.action}',
      theme: '${widget.theme}',
      callback: function(token) {
        parent._turnstileOnToken$_viewType(token);
      },
      'expired-callback': function() {
        parent._turnstileOnExpired$_viewType();
      },
      'error-callback': function() {
        parent._turnstileOnError$_viewType();
      }
    });
  </script>
</body>
</html>''';

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) => iframe);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    try {
      js.context['_turnstileOnToken$_viewType'] = null;
      js.context['_turnstileOnExpired$_viewType'] = null;
      js.context['_turnstileOnError$_viewType'] = null;
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_viewType.isEmpty) {
      return const SizedBox(width: 300, height: 65, child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))));
    }
    return SizedBox(
      width: 300,
      height: 65,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}