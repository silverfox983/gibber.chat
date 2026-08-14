import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/db_init_native.dart' if (dart.library.html) 'services/db_init_web.dart';
import './services/auth_service.dart';
import './providers/chat_provider.dart';
import './providers/call_provider.dart';
import './services/avatar_cache_service.dart';
import './services/call_history_service.dart';
import './services/account_status_notification_service.dart';
import './services/resource_scheduler_service.dart';
import './services/transcription_service.dart';
import './services/assistant_service.dart';
import './services/miner_service.dart';
import './services/entitlement_service.dart';
import './services/backend_config.dart';
import './providers/theme_provider.dart';
import './theme/app_theme.dart';
import './services/desktop_lifecycle_service.dart';
import './services/mobile_lifecycle_service.dart';
import './router/app_router.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await DesktopLifecycleService.instance.init();

    await MobileLifecycleService.instance.init();

    await initDatabase();

    AvatarCacheService().init();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('FRAMEWORK ERROR: ${details.exception}\n${details.stack}');
    };

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
  ResourceSchedulerService? _resourceScheduler;
  TranscriptionService? _transcriptionService;
  AssistantService? _assistantService;
  MinerService? _minerService;
  EntitlementService? _entitlementService;
  BackendConfig? _backendConfig;
  final AccountStatusNotificationService _accountStatusNotifications =
      AccountStatusNotificationService.instance;

  @override
  void initState() {
    super.initState();
    _initializeProviders();
  }

  void _initializeProviders() {
    try {
      _errorSource = 'BackendConfig';
      _backendConfig = BackendConfig();

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

      _errorSource = 'ResourceScheduler';
      _resourceScheduler = ResourceSchedulerService();

      _errorSource = 'EntitlementService';
      _entitlementService = EntitlementService();

      _errorSource = 'TranscriptionService';
      _transcriptionService = TranscriptionService(_resourceScheduler!);
      _transcriptionService!.setEntitlementService(_entitlementService!);

      _errorSource = 'AssistantService';
      _assistantService = AssistantService(_resourceScheduler!, _transcriptionService);
      _assistantService!.setEntitlementService(_entitlementService!);

      _errorSource = 'MinerService';
      _minerService = MinerService(_resourceScheduler!);
      _minerService!.setEntitlementService(_entitlementService!);

      _entitlementService!.setBackendUrl(_backendConfig!.apiUrl);
      _minerService!.setBackendUrl(_backendConfig!.apiUrl);
      _minerService!.setPoolUrl(_backendConfig!.poolUrl);

      _backendConfig!.addListener(() {
        _entitlementService?.setBackendUrl(_backendConfig!.apiUrl);
        _minerService?.setBackendUrl(_backendConfig!.apiUrl);
        _minerService?.setPoolUrl(_backendConfig!.poolUrl);
      });

      _chatProvider!.initialize(_authService!);
      _callProvider!.initialize(_authService!, _callHistoryService!, scheduler: _resourceScheduler!);
      _accountStatusNotifications.start(_authService!);

      _authService!.addListener(() {
        MobileLifecycleService.instance.syncServiceState(_authService!.isAuthenticated);
      });

      _authService!.onAuthenticated = (bareJid) {
        _entitlementService?.fetchEntitlement(bareJid);
        _minerService?.setJid(bareJid);
        if (_minerService?.consent == true && _minerService?.status == MinerStatus.idle) {
          _minerService?.startMining();
        }
      };

      MobileLifecycleService.instance.syncServiceState(_authService!.isAuthenticated);

      setState(() {});
    } catch (e, stack) {
      debugPrint('STARTUP CRASH IN $_errorSource: $e\n$stack');
      setState(() {
        _startupError = 'CRASH IN $_errorSource: $e';
      });
    }
  }

  @override
  void dispose() {
    _accountStatusNotifications.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          backgroundColor: Color(0xFFFF007F),
          body: Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }

    final router = createAppRouter(
      authService: _authService!,
      chatProvider: _chatProvider!,
      callProvider: _callProvider!,
    );

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _authService!),
        ChangeNotifierProvider.value(value: _chatProvider!),
        ChangeNotifierProvider.value(value: _callProvider!),
        ChangeNotifierProvider.value(value: _callHistoryService!),
        ChangeNotifierProvider.value(value: _themeProvider!),
        ChangeNotifierProvider.value(value: _resourceScheduler!),
        ChangeNotifierProvider.value(value: _transcriptionService!),
        ChangeNotifierProvider.value(value: _assistantService!),
        ChangeNotifierProvider.value(value: _minerService!),
        ChangeNotifierProvider.value(value: _entitlementService!),
        ChangeNotifierProvider.value(value: _backendConfig!),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, tp, _) => MaterialApp.router(
          title: 'Gibber',
          themeMode: tp.themeMode,
          theme: GibberTheme.light,
          darkTheme: GibberTheme.dark,
          routerConfig: router,
          debugShowCheckedModeBanner: false,
        ),
      ),
    );
  }
}