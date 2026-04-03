import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import './services/auth_service.dart';
import './providers/chat_provider.dart';
import './providers/call_provider.dart';
import './screens/login_screen.dart';
import './screens/main_chat_screen.dart';
import './screens/call_screen.dart';
import './services/avatar_cache_service.dart';
import './services/call_history_service.dart';
import './providers/theme_provider.dart';
import './theme/app_theme.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Initialize Database for Windows (Phase 9 Robustness)
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      debugPrint('DB: sqflite_ffi initialized');
    }
    
    // Initialize Avatar Cache (Phase 2 Robustness)
    AvatarCacheService().init();
    
    // Framework Error Catcher
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('FRAMEWORK ERROR: ${details.exception}\n${details.stack}');
    };

    // Global "Nuclear" Error Widget Override
    // This turns all red screens into NEON ORANGE for diagnostics
    ErrorWidget.builder = (FlutterErrorDetails details) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          color: Colors.orangeAccent,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'GLOBAL NUCLEAR CRASH: ${details.exception}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    };

    // NATIVE HEARTBEAT (Isolate Death Watch)
    Timer.periodic(const Duration(seconds: 1), (timer) {
      debugPrint('HEARTBEAT: ISOLATE ALIVE (Epoch: ${DateTime.now().millisecondsSinceEpoch})');
    });

    runApp(const ChatApp());
  }, (error, stack) {
    debugPrint('ZONED ERROR (CAUGHT BY WATCHDOG): $error\n$stack');
  });
}

class ChatApp extends StatefulWidget {
  const ChatApp({super.key});

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  String? _startupError;
  String? _errorSource;

  AuthService? _authService;
  ChatProvider? _chatProvider;
  CallProvider? _callProvider;
  CallHistoryService? _callHistoryService;
  ThemeProvider? _themeProvider;

  @override
  void initState() {
    super.initState();
    _initializeProviders();
  }

  void _initializeProviders() {
    try {
      _errorSource = 'AuthService';
      _authService = AuthService();
      
      _errorSource = 'ChatProvider';
      _chatProvider = ChatProvider();
      
      _errorSource = 'CallProvider';
      _callProvider = CallProvider();

      _errorSource = 'CallHistoryService';
      _callHistoryService = CallHistoryService();

      _errorSource = 'ThemeProvider';
      _themeProvider = ThemeProvider();
      
      // LINKING: Connect providers to AuthService for unified signaling
      _chatProvider!.initialize(_authService!);
      _callProvider!.initialize(_authService!, _callHistoryService!);
      
      setState(() {});
    } catch (e, stack) {
      debugPrint('STARTUP CRASH IN $_errorSource: $e\n$stack');
      setState(() {
        _startupError = 'CRASH IN $_errorSource: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('HEARTBEAT: App Build Running [isInitialized: ${_authService != null}]');
    if (_startupError != null) {
      return MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.yellow,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'SAFE-BOOT CRASH: $_startupError',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    if (_authService == null) {
      return const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFFFF007F), // VIBRANT PINK
          body: Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _authService!),
        ChangeNotifierProvider.value(value: _chatProvider!),
        ChangeNotifierProvider.value(value: _callProvider!),
        ChangeNotifierProvider.value(value: _callHistoryService!),
        ChangeNotifierProvider.value(value: _themeProvider!),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, tp, _) => MaterialApp(
          title: 'Gibber',
          themeMode: tp.themeMode,
          theme: GibberTheme.light,
          darkTheme: GibberTheme.dark,
          home: const AuthenticationWrapper(),
          debugShowCheckedModeBanner: false,
        ),
      ),
    );
  }
}

class AuthenticationWrapper extends StatefulWidget {
  const AuthenticationWrapper({super.key});

  @override
  State<AuthenticationWrapper> createState() => _AuthenticationWrapperState();
}

class _AuthenticationWrapperState extends State<AuthenticationWrapper> {
  bool _checkedAuth = false;

  @override
  void initState() {
    super.initState();
    _checkInitialAuth();
  }

  Future<void> _checkInitialAuth() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    await authService.autoLogin();
    if (mounted) {
      setState(() {
        _checkedAuth = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedAuth) {
      return const Scaffold(
        backgroundColor: Color(0xFF00FFFF), // NEON CYAN LOADING
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final authService = Provider.of<AuthService>(context);
    final callProvider = Provider.of<CallProvider>(context);

    // SOLID PULSE: Use 100% opaque colors to prevent Windows black-buffer leaking
    final pulseColor = (DateTime.now().second % 2 == 0) ? const Color(0xFF00FFFF) : const Color(0xFF00CED1);

    debugPrint('AUTH_WRAPPER: State Check - Auth: ${authService.isAuthenticated}, ActiveAcc: ${authService.activeAccountId}');

    if (authService.isAuthenticated) {
      debugPrint('AUTH_WRAPPER: Rendering MAIN CHAT (id: ${authService.activeAccountId})');
      
      if (callProvider.state != CallState.idle) {
        return const CallScreen();
      }
      
      return MainChatScreen();
    } else {
      debugPrint('AUTH_WRAPPER: Rendering LOGIN SCREEN (Auth: false)');
      return Container(color: pulseColor, child: const LoginScreen());
    }

    // THE VOID CATCHER
    // If you see a BRIGHT WHITE screen, the navigation logic above has a hole.
    // ignore: dead_code
    return const Scaffold(
      backgroundColor: Colors.white, // PURE WHITE DIAGNOSTIC
      body: Center(
        child: Text(
          'THE VOID CATCHER: LOGIC FALL-THROUGH',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
