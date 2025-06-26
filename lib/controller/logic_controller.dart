import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class LogicController {
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  FirebaseMessaging messaging = FirebaseMessaging.instance;
  final Uuid _uuid = Uuid();

  /// Local notifications plugin
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  /// Initialize Firebase and setup notifications
  Future<void> initializeFirebase() async {
    try {
      // Initialize local notifications first
      await _initializeLocalNotifications();

      // Request all necessary permissions
      await requestAllPermissions();

      // Setup background message handler
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // Setup foreground message handler
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('Received foreground message: ${message.notification?.title}');
        _showLocalNotification(message);
      });

      // Handle notification tap when app is in background
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        print('Message clicked from background! ${message.data}');
        _handleNotificationTap(message);
      });

      // Handle initial message when app is opened from terminated state
      RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        print('App opened from terminated state via notification: ${initialMessage.data}');
        _handleNotificationTap(initialMessage);
      }

      print("✅ Firebase initialized successfully");
    } catch (e) {
      print("❌ Error initializing Firebase: $e");
    }
  }

  /// Initialize local notifications
  Future<void> _initializeLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/launcher_icon');

    const DarwinInitializationSettings initializationSettingsIOS =
    DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings initializationSettings =
    InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        print('Local notification tapped: ${response.payload}');
        // Handle notification tap
      },
    );
  }

  /// Show local notification when app is in foreground
  Future<void> _showLocalNotification(RemoteMessage message) async {
    const AndroidNotificationDetails androidNotificationDetails =
    AndroidNotificationDetails(
      'high_importance_channel',
      'High Importance Notifications',
      channelDescription: 'This channel is used for important notifications.',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
    );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    await flutterLocalNotificationsPlugin.show(
      message.hashCode,
      message.notification?.title ?? 'New Notification',
      message.notification?.body ?? 'You have a new message',
      notificationDetails,
      payload: jsonEncode(message.data),
    );
  }

  /// Handle notification tap
  void _handleNotificationTap(RemoteMessage message) {
    // Add your custom logic here
    print('Notification tapped with data: ${message.data}');

    // Example: Navigate to specific screen based on notification data
    if (message.data.containsKey('url')) {
      String url = message.data['url'];
      print('Should navigate to: $url');
      // You can use a callback or event system to notify your WebView
    }
  }

  /// Background message handler (must be top-level function)
  static Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    print("🔔 Handling background message: ${message.messageId}");
    print("Title: ${message.notification?.title}");
    print("Body: ${message.notification?.body}");
    print("Data: ${message.data}");

    // You can also show local notification here if needed
  }

  /// Register device for notifications
  Future<void> registerDeviceForNotifications(String customerId, String pushNotificationSecret, String baseUrl) async {
    try {
      String deviceId = await getOrCreateDeviceId();
      String fcmToken = await getFirebaseToken();
      String apiEndpoint = _getApiEndpoint(baseUrl);

      await sendNotificationRegistration(customerId, deviceId, pushNotificationSecret, fcmToken, apiEndpoint);
    } catch (e) {
      print("❌ Error in device registration: $e");
    }
  }

  /// Get Firebase FCM token
  Future<String> getFirebaseToken() async {
    try {
      String? token = await messaging.getToken();
      if (token != null) {
        print("🔑 Firebase FCM Token: $token");

        // Store token in SharedPreferences
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', token);

        return token;
      }
    } catch (e) {
      print("❌ Error getting Firebase token: $e");
    }
    return '';
  }

  /// Get or create unique device ID
  Future<String> getOrCreateDeviceId() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String? storedDeviceId = prefs.getString('device_id');

      if (storedDeviceId != null && storedDeviceId.isNotEmpty) {
        return storedDeviceId;
      }

      String newDeviceId = _uuid.v4();
      await prefs.setString('device_id', newDeviceId);
      print("📱 Generated new device ID: $newDeviceId");
      return newDeviceId;
    } catch (e) {
      print("❌ Error generating device ID: $e");
      return _uuid.v4();
    }
  }

  /// Determine API endpoint
  String _getApiEndpoint(String baseUrl) {
    return 'https://app.roadeeto.com/api/register-device';
  }

  /// Send registration to API
  Future<void> sendNotificationRegistration(String customerId, String deviceId, String pushNotificationSecret, String fcmToken, String apiEndpoint) async {
    Map<String, dynamic> data = {
      "customer_id": int.tryParse(customerId) ?? customerId,
      "push_notification_secret": pushNotificationSecret,
      "device_id": fcmToken,
      "fcm_token": fcmToken,
      "platform": Platform.isAndroid ? "android" : "ios",
      "app_version": "1.0.0", // Add your app version
      "timestamp": DateTime.now().toIso8601String(),
    };

    try {
      print("📡 Registering device with API: $apiEndpoint");

      var response = await http.post(
        Uri.parse(apiEndpoint),
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: jsonEncode(data),
      );

      if (response.statusCode == 200) {
        print("✅ Device registered successfully");

        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_registered_customer_id', customerId);
        await prefs.setString('last_registered_secret', pushNotificationSecret);
        await prefs.setString('registration_timestamp', DateTime.now().toIso8601String());
        await prefs.setBool('is_registered', true);
      } else {
        print("❌ Failed to register device: ${response.statusCode}");
        print("Error response: ${response.body}");
      }
    } catch (e) {
      print("❌ Exception in sendNotificationRegistration: $e");
    }
  }

  /// Request all permissions
  Future<void> requestAllPermissions() async {
    try {
      // Firebase notification permissions
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
        criticalAlert: true,
        carPlay: false,
        announcement: false,
      );

      print("🔔 Notification permission status: ${settings.authorizationStatus}");

      // Request other permissions
      Map<Permission, PermissionStatus> permissions = await [
        Permission.location,
        Permission.locationWhenInUse,
        Permission.camera,
        Permission.microphone,
        Permission.photos,
        if (Platform.isAndroid) Permission.storage,
        if (Platform.isAndroid) Permission.notification,
      ].request();

      permissions.forEach((permission, status) {
        print("📋 ${permission.toString()}: ${status.toString()}");
      });

    } catch (e) {
      print("❌ Error requesting permissions: $e");
    }
  }

  /// Test notification (for debugging)
  Future<void> testNotification() async {
    const AndroidNotificationDetails androidNotificationDetails =
    AndroidNotificationDetails(
      'test_channel',
      'Test Notifications',
      channelDescription: 'Channel for testing notifications',
      importance: Importance.high,
      priority: Priority.high,
    );

    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
      iOS: DarwinNotificationDetails(),
    );

    await flutterLocalNotificationsPlugin.show(
      0,
      'Test Notification',
      'This is a test notification from your app!',
      notificationDetails,
    );
  }

  /// Get device info
  Future<Map<String, String>> getDeviceInfo() async {
    Map<String, String> deviceData = {};

    try {
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        deviceData = {
          'platform': 'Android',
          'model': androidInfo.model,
          'manufacturer': androidInfo.manufacturer,
          'version': androidInfo.version.release,
          'sdk': androidInfo.version.sdkInt.toString(),
        };
      } else if (Platform.isIOS) {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        deviceData = {
          'platform': 'iOS',
          'model': iosInfo.model,
          'name': iosInfo.name,
          'version': iosInfo.systemVersion,
        };
      }
    } catch (e) {
      print("❌ Error getting device info: $e");
    }

    return deviceData;
  }

  /// Check if device is registered
  Future<bool> isDeviceRegistered() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool('is_registered') ?? false;
    } catch (e) {
      return false;
    }
  }
}