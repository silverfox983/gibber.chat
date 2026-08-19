import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../providers/chat_provider.dart';
import '../providers/call_provider.dart';
import '../services/auth_service.dart';
import '../models/chat_models.dart';
import '../models/space_models.dart';
import '../services/spaces_service.dart';
import '../screens/landing_screen.dart';
import '../screens/login_screen.dart';
import '../screens/main_chat_screen.dart';
import '../screens/call_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/add_contact_screen.dart';
import '../screens/contact_profile_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/account_preferences_screen.dart';
import '../screens/security_settings_screen.dart';
import '../screens/identity_trust_screen.dart';
import '../screens/invite_screen.dart';
import '../screens/recordings_screen.dart';
import '../screens/tier_screen.dart';
import '../screens/connections_screen.dart';
import '../screens/create_room_screen.dart';
import '../screens/room_info_screen.dart';
import '../screens/room_settings_screen.dart';
import '../screens/room_affiliation_screen.dart';
import '../screens/feed_screen.dart';
import '../screens/spaces_screen.dart';
import '../screens/space_settings_screen.dart';
import '../screens/post_detail_screen.dart';
import '../screens/post_thread_screen.dart';
import '../screens/article_view_screen.dart';
import '../screens/group_settings_screen.dart';
import '../screens/new_message_screen.dart';
import '../screens/appearance_settings_screen.dart';
import '../screens/register_screen.dart';

CustomTransitionPage<void> _fadePage({
  required GoRouterState state,
  required Widget child,
  bool slideFromRight = true,
}) {
  return CustomTransitionPage(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      if (!slideFromRight) {
        return FadeTransition(opacity: curved, child: child);
      }
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 180),
  );
}

CustomTransitionPage<void> _slideUpPage({
  required GoRouterState state,
  required Widget child,
}) {
  return CustomTransitionPage(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 200),
  );
}

GoRouter createAppRouter({
  required AuthService authService,
  required ChatProvider chatProvider,
  required CallProvider callProvider,
}) {
  return GoRouter(
    debugLogDiagnostics: kDebugMode,
    initialLocation: '/',
    refreshListenable: _AuthRefreshNotifier(authService),
    redirect: (context, state) {
      final isAuthenticated = authService.isAuthenticated;
      final isOnLanding = state.matchedLocation == '/';
      final isOnLogin = state.matchedLocation == '/login';
      final isOnRegister = state.matchedLocation == '/register';
      final isOnAuthRoute = state.matchedLocation.startsWith('/app');

      if (!isAuthenticated && isOnAuthRoute) return '/login';
      if (isAuthenticated && (isOnLogin || isOnLanding || isOnRegister)) return '/app';

      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        name: 'landing',
        pageBuilder: (context, state) => _fadePage(state: state, child: const LandingScreen(), slideFromRight: false),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        pageBuilder: (context, state) => _fadePage(state: state, child: LoginScreen(
          isAddingAccount: state.uri.queryParameters['addAccount'] == 'true',
        ), slideFromRight: false),
      ),
      GoRoute(
        path: '/register',
        name: 'register',
        pageBuilder: (context, state) => _fadePage(state: state, child: const RegisterScreen(), slideFromRight: false),
      ),
      ShellRoute(
        builder: (context, state, child) {
          return ListenableBuilder(
            listenable: callProvider,
            builder: (context, _) {
              return Stack(
                children: [
                  child,
                  if (callProvider.state != CallState.idle)
                    const CallScreen(),
                ],
              );
            },
          );
        },
        routes: [
          GoRoute(
            path: '/app',
            name: 'home',
            pageBuilder: (context, state) => _fadePage(state: state, child: const MainChatScreen()),
            routes: [
              GoRoute(
                path: 'contacts',
                name: 'contacts',
                pageBuilder: (context, state) => _fadePage(state: state, child: const ContactsScreen()),
              ),
              GoRoute(
                path: 'add-contact',
                name: 'addContact',
                pageBuilder: (context, state) => _fadePage(state: state, child: const AddContactScreen()),
              ),
              GoRoute(
                path: 'contact-profile',
                name: 'contactProfile',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: ContactProfileScreen(
                    contact: args['contact'] as Contact,
                  ));
                },
              ),
              GoRoute(
                path: 'profile',
                name: 'profile',
                pageBuilder: (context, state) => _fadePage(state: state, child: const ProfileScreen(isSidebar: false)),
              ),
              GoRoute(
                path: 'appearance',
                name: 'appearance',
                pageBuilder: (context, state) => _fadePage(state: state, child: const AppearanceSettingsScreen()),
              ),
              GoRoute(
                path: 'preferences',
                name: 'preferences',
                pageBuilder: (context, state) => _fadePage(state: state, child: const AccountPreferencesScreen()),
                routes: [
                  GoRoute(
                    path: 'security',
                    name: 'security',
                    pageBuilder: (context, state) => _fadePage(state: state, child: const SecuritySettingsScreen()),
                    routes: [
                      GoRoute(
                        path: 'identity',
                        name: 'identity',
                        pageBuilder: (context, state) => _fadePage(state: state, child: const IdentityTrustScreen()),
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(
                path: 'invite',
                name: 'invite',
                pageBuilder: (context, state) => _fadePage(state: state, child: const InviteScreen()),
              ),
              GoRoute(
                path: 'recordings',
                name: 'recordings',
                pageBuilder: (context, state) => _fadePage(state: state, child: const RecordingsScreen()),
              ),
              GoRoute(
                path: 'tier',
                name: 'tier',
                pageBuilder: (context, state) => _fadePage(state: state, child: const TierScreen()),
              ),
              GoRoute(
                path: 'connections',
                name: 'connections',
                pageBuilder: (context, state) => _fadePage(state: state, child: const ConnectionsScreen()),
              ),
              GoRoute(
                path: 'create-room',
                name: 'createRoom',
                pageBuilder: (context, state) => _fadePage(state: state, child: const CreateRoomScreen()),
              ),
              GoRoute(
                path: 'room-info',
                name: 'roomInfo',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: RoomInfoScreen(
                    room: args['room'] as Map<String, dynamic>,
                    accountId: args['accountId'] as String,
                  ));
                },
              ),
              GoRoute(
                path: 'room-settings',
                name: 'roomSettings',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: RoomSettingsScreen(
                    room: args['room'] as Conversation,
                  ));
                },
              ),
              GoRoute(
                path: 'room-affiliation',
                name: 'roomAffiliation',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: RoomAffiliationScreen(
                    room: args['room'] as Conversation,
                  ));
                },
              ),
              GoRoute(
                path: 'new-message',
                name: 'newMessage',
                pageBuilder: (context, state) => _fadePage(state: state, child: const NewMessageScreen()),
              ),
              GoRoute(
                path: 'feed',
                name: 'feed',
                pageBuilder: (context, state) => _fadePage(state: state, child: const FeedScreen()),
              ),
              GoRoute(
                path: 'spaces',
                name: 'spaces',
                pageBuilder: (context, state) => _fadePage(state: state, child: const SpacesScreen()),
              ),
              GoRoute(
                path: 'space-settings',
                name: 'spaceSettings',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: SpaceSettingsScreen(
                    space: args['space'] as SpaceNode,
                    spacesService: args['spacesService'] as SpacesService,
                  ));
                },
              ),
              GoRoute(
                path: 'post-detail',
                name: 'postDetail',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: PostDetailScreen(
                    post: args['post'] as SpaceItem,
                    space: args['space'] as SpaceNode,
                    spacesService: args['spacesService'] as SpacesService,
                    allItems: args['allItems'] as List<SpaceItem>,
                  ));
                },
              ),
              GoRoute(
                path: 'post-thread',
                name: 'postThread',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: PostThreadScreen(
                    post: args['post'] as SpaceItem,
                    space: args['space'] as SpaceNode,
                    spacesService: args['spacesService'] as SpacesService,
                  ));
                },
              ),
              GoRoute(
                path: 'article-view',
                name: 'articleView',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: ArticleViewScreen(
                    item: args['item'] as SpaceItem,
                    spacesService: args['spacesService'] as SpacesService?,
                  ));
                },
              ),
              GoRoute(
                path: 'group-settings',
                name: 'groupSettings',
                pageBuilder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return _fadePage(state: state, child: GroupSettingsScreen(
                    conversation: args['conversation'] as Conversation,
                  ));
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

class _AuthRefreshNotifier extends ChangeNotifier {
  final AuthService _authService;
  _AuthRefreshNotifier(this._authService) {
    _authService.addListener(_notify);
  }

  void _notify() => notifyListeners();

  @override
  void dispose() {
    _authService.removeListener(_notify);
    super.dispose();
  }
}