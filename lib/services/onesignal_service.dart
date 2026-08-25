import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

typedef PushSubscriptionCallback = void Function(OSPushSubscriptionChangedState state);

/// Centralized OneSignal Manager for e-KOPI Polda Kalteng
class OneSignalService {
  OneSignalService._internal();
  static final OneSignalService instance = OneSignalService._internal();

  /// Official OneSignal App ID provided by user
  static const String appId = '9addb9c5-3057-4b4e-9536-4cb8d89c5d7d';

  bool _isInitialized = false;

  /// Initialize OneSignal SDK
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      if (kDebugMode) {
        OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
      } else {
        OneSignal.Debug.setLogLevel(OSLogLevel.none);
      }

      // Initialize with App ID
      OneSignal.initialize(appId);
      _isInitialized = true;
      debugPrint('OneSignal SDK initialized successfully with App ID: $appId');
    } catch (e) {
      debugPrint('Error initializing OneSignal SDK: $e');
    }
  }

  /// Request push notification permission
  Future<bool> requestPushPermission() async {
    try {
      final granted = await OneSignal.Notifications.requestPermission(true);
      return granted;
    } catch (e) {
      debugPrint('Error requesting push notification permission: $e');
      return false;
    }
  }

  /// Login user ID
  Future<void> loginUser(String externalUserId) async {
    try {
      await OneSignal.login(externalUserId);
      debugPrint('OneSignal user logged in with ID: $externalUserId');
    } catch (e) {
      debugPrint('Error logging in OneSignal user: $e');
    }
  }

  /// Logout user
  Future<void> logoutUser() async {
    try {
      await OneSignal.logout();
      debugPrint('OneSignal user logged out');
    } catch (e) {
      debugPrint('Error logging out OneSignal user: $e');
    }
  }

  /// Send custom tag
  Future<void> sendTag(String key, String value) async {
    try {
      await OneSignal.User.addTagWithKey(key, value);
    } catch (e) {
      debugPrint('Error sending OneSignal tag: $e');
    }
  }

  /// Add Push Subscription Observer
  void addPushSubscriptionObserver(PushSubscriptionCallback listener) {
    try {
      OneSignal.User.pushSubscription.addObserver(listener);
    } catch (e) {
      debugPrint('Error adding push subscription observer: $e');
    }
  }

  /// Remove Push Subscription Observer
  void removePushSubscriptionObserver(PushSubscriptionCallback listener) {
    try {
      OneSignal.User.pushSubscription.removeObserver(listener);
    } catch (e) {
      debugPrint('Error removing push subscription observer: $e');
    }
  }

  /// Current Push Subscription ID
  String? get pushSubscriptionId => OneSignal.User.pushSubscription.id;
}
