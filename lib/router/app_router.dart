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
import '../screens/transports_screen.dart';
import '../screens/create_room_screen.dart';
import '../screens/room_discovery_screen.dart';
import '../screens/room_info_screen.dart';
import '../screens/room_settings_screen.dart';
import '../screens/room_affiliation_screen.dart';
import '../screens/nexus_search_screen.dart';
import '../screens/feed_screen.dart';
import '../screens/spaces_screen.dart';
import '../screens/space_settings_screen.dart';
import '../screens/post_detail_screen.dart';
import '../screens/post_thread_screen.dart';
import '../screens/article_view_screen.dart';
import '../screens/group_settings_screen.dart';
import '../screens/register_screen.dart';

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
        builder: (context, state) => const LandingScreen(),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => LoginScreen(
          isAddingAccount: state.uri.queryParameters['addAccount'] == 'true',
        ),
      ),
      GoRoute(
        path: '/register',
        name: 'register',
        builder: (context, state) => const RegisterScreen(),
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
            builder: (context, state) => const MainChatScreen(),
            routes: [
              GoRoute(
                path: 'contacts',
                name: 'contacts',
                builder: (context, state) => const ContactsScreen(),
              ),
              GoRoute(
                path: 'add-contact',
                name: 'addContact',
                builder: (context, state) => const AddContactScreen(),
              ),
              GoRoute(
                path: 'contact-profile',
                name: 'contactProfile',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return ContactProfileScreen(
                    contact: args['contact'] as Contact,
                  );
                },
              ),
              GoRoute(
                path: 'profile',
                name: 'profile',
                builder: (context, state) => const ProfileScreen(isSidebar: false),
              ),
              GoRoute(
                path: 'preferences',
                name: 'preferences',
                builder: (context, state) => const AccountPreferencesScreen(),
                routes: [
                  GoRoute(
                    path: 'security',
                    name: 'security',
                    builder: (context, state) => const SecuritySettingsScreen(),
                    routes: [
                      GoRoute(
                        path: 'identity',
                        name: 'identity',
                        builder: (context, state) => const IdentityTrustScreen(),
                      ),
                    ],
                  ),
                ],
              ),
              GoRoute(
                path: 'invite',
                name: 'invite',
                builder: (context, state) => const InviteScreen(),
              ),
              GoRoute(
                path: 'recordings',
                name: 'recordings',
                builder: (context, state) => const RecordingsScreen(),
              ),
              GoRoute(
                path: 'tier',
                name: 'tier',
                builder: (context, state) => const TierScreen(),
              ),
              GoRoute(
                path: 'transports',
                name: 'transports',
                builder: (context, state) => const TransportsScreen(),
              ),
              GoRoute(
                path: 'create-room',
                name: 'createRoom',
                builder: (context, state) => const CreateRoomScreen(),
              ),
              GoRoute(
                path: 'room-discovery',
                name: 'roomDiscovery',
                builder: (context, state) => const RoomDiscoveryScreen(),
              ),
              GoRoute(
                path: 'room-info',
                name: 'roomInfo',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return RoomInfoScreen(
                    room: args['room'] as Map<String, dynamic>,
                    accountId: args['accountId'] as String,
                  );
                },
              ),
              GoRoute(
                path: 'room-settings',
                name: 'roomSettings',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return RoomSettingsScreen(
                    room: args['room'] as Conversation,
                  );
                },
              ),
              GoRoute(
                path: 'room-affiliation',
                name: 'roomAffiliation',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return RoomAffiliationScreen(
                    room: args['room'] as Conversation,
                  );
                },
              ),
              GoRoute(
                path: 'search',
                name: 'search',
                builder: (context, state) => const NexusSearchScreen(),
              ),
              GoRoute(
                path: 'feed',
                name: 'feed',
                builder: (context, state) => const FeedScreen(),
              ),
              GoRoute(
                path: 'spaces',
                name: 'spaces',
                builder: (context, state) => const SpacesScreen(),
              ),
              GoRoute(
                path: 'space-settings',
                name: 'spaceSettings',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return SpaceSettingsScreen(
                    space: args['space'] as SpaceNode,
                    spacesService: args['spacesService'] as SpacesService,
                  );
                },
              ),
              GoRoute(
                path: 'post-detail',
                name: 'postDetail',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return PostDetailScreen(
                    post: args['post'] as SpaceItem,
                    space: args['space'] as SpaceNode,
                    spacesService: args['spacesService'] as SpacesService,
                    allItems: args['allItems'] as List<SpaceItem>,
                  );
                },
              ),
              GoRoute(
                path: 'post-thread',
                name: 'postThread',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return PostThreadScreen(
                    post: args['post'] as SpaceItem,
                    space: args['space'] as SpaceNode,
                    spacesService: args['spacesService'] as SpacesService,
                  );
                },
              ),
              GoRoute(
                path: 'article-view',
                name: 'articleView',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return ArticleViewScreen(
                    item: args['item'] as SpaceItem,
                    spacesService: args['spacesService'] as SpacesService?,
                  );
                },
              ),
              GoRoute(
                path: 'group-settings',
                name: 'groupSettings',
                builder: (context, state) {
                  final args = state.extra as Map<String, dynamic>;
                  return GroupSettingsScreen(
                    conversation: args['conversation'] as Conversation,
                  );
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