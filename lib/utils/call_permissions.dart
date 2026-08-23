import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests the microphone (and camera, for video calls) permissions needed
/// to start a call. Shows a SnackBar with an open-settings action if the user
/// denied a required permission and returns false.
Future<bool> requestCallPermissions(
  BuildContext context, {
  required bool isVideo,
  bool showSettingsAction = true,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final statuses = await [
    Permission.microphone,
    if (isVideo) Permission.camera,
  ].request();

  if (statuses[Permission.microphone] != PermissionStatus.granted) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          isVideo
              ? 'Camera and microphone permissions are required for video calls.'
              : 'Microphone permission is required for voice calls.',
        ),
        action: showSettingsAction
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () => openAppSettings(),
              )
            : null,
      ),
    );
    return false;
  }

  if (isVideo && statuses[Permission.camera] != PermissionStatus.granted) {
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Camera permission is required for video calls.'),
        action: showSettingsAction
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () => openAppSettings(),
              )
            : null,
      ),
    );
    return false;
  }

  return true;
}
