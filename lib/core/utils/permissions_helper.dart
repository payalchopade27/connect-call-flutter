import 'package:permission_handler/permission_handler.dart';

class PermissionsHelper {
  /// Request Camera and Microphone permissions required for WebRTC calls
  static Future<bool> requestCallPermissions({required bool isVideoCall}) async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.microphone,
      if (isVideoCall) Permission.camera,
    ].request();

    bool micGranted = statuses[Permission.microphone]?.isGranted ?? false;
    bool cameraGranted = isVideoCall
        ? (statuses[Permission.camera]?.isGranted ?? false)
        : true;

    return micGranted && cameraGranted;
  }

  /// Check if call permissions are already granted
  static Future<bool> hasCallPermissions({required bool isVideoCall}) async {
    bool micGranted = await Permission.microphone.isGranted;
    bool cameraGranted = isVideoCall ? await Permission.camera.isGranted : true;
    return micGranted && cameraGranted;
  }
}
