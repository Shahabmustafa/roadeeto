import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'logic_controller.dart';

class NetworkConnectionController extends ChangeNotifier {
  bool _hasInternet = false;
  bool _isLoading = false;
  bool _hasError = false;
  String _errorMessage = '';
  WebViewController? _controller;

  // LogicController instance
  final LogicController _logicController = LogicController();

  /// Getters
  bool get hasInternet => _hasInternet;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  String get errorMessage => _errorMessage;
  WebViewController? get controller => _controller;

  /// Request location permission
  Future<bool> requestLocationPermission() async {
    try {
      var status = await Permission.location.status;

      if (status.isDenied) {
        status = await Permission.location.request();
      }

      if (status.isPermanentlyDenied) {
        // Show dialog to open app settings
        await openAppSettings();
        return false;
      }

      return status.isGranted;
    } catch (e) {
      print('Error requesting location permission: $e');
      return false;
    }
  }

  /// Handle deep link navigation
  Future<void> handleDeepLink(String url) async {
    if (_controller != null) {
      print('Loading deep link URL in WebView: $url');
      await _controller!.loadRequest(Uri.parse(url));
    }
  }

  /// Open external URL manually
  Future<void> openExternalUrl(String url) async {
    try {
      print('Opening external URL: $url');
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        print('External URL opened successfully');
      } else {
        print('Cannot launch URL: $url');
      }
    } catch (e) {
      print('Error opening external URL: $e');
    }
  }

  /// Get current location
  Future<Position?> getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('Location services are disabled.');
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('Location permissions are denied');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('Location permissions are permanently denied');
        return null;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      return position;
    } catch (e) {
      print('Error getting current location: $e');
      return null;
    }
  }

  /// Check internet connection and initialize WebView
  Future<void> checkConnection(String url) async {
    final connectivityResult = await Connectivity().checkConnectivity();
    final connected = connectivityResult != ConnectivityResult.none;

    _hasInternet = connected;
    _hasError = false;
    _errorMessage = '';
    notifyListeners();

    if (connected) {
      // Request location permission first
      await requestLocationPermission();

      // Initialize Firebase first
      await _logicController.initializeFirebase();
      await _initializeWebView(url);
    }
  }

  /// Initialize WebView with all configurations
  Future<void> _initializeWebView(String url) async {
    final cookieManager = WebViewCookieManager();

    // Get device ID for cookie
    String deviceId = await _logicController.getOrCreateDeviceId();
    String fcmToken = await _logicController.getFirebaseToken();

    /// Add permanent cookies with max age
    await cookieManager.setCookie(
      WebViewCookie(
        name: 'platform',
        value: 'mobile_app',
        domain: Uri.parse(url).host,
        path: '/',
      ),
    );

    // Add permanent device_id cookie that client can read
    await cookieManager.setCookie(
      WebViewCookie(
        name: 'device_id',
        value: fcmToken,
        domain: Uri.parse(url).host,
        path: '/',
      ),
    );

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
    // Enable caching
      ..setBackgroundColor(const Color(0x00000000))
    // Add location channel
      ..addJavaScriptChannel(
        'LocationChannel',
        onMessageReceived: (JavaScriptMessage message) async {
          await _handleLocationRequest();
        },
      )
      ..addJavaScriptChannel(
        'ExternalLinkOpener',
        onMessageReceived: (JavaScriptMessage message) async {
          final externalUrl = message.message;
          print('Received external URL from WebView: $externalUrl');
          await openExternalUrl(externalUrl);
        },
      )
    // Manual External URL Channel - NEW
      ..addJavaScriptChannel(
        'ManualExternalUrl',
        onMessageReceived: (JavaScriptMessage message) async {
          final externalUrl = message.message;
          print('Manual external URL request: $externalUrl');
          await openExternalUrl(externalUrl);
        },
      )
    // AJAX Response Monitor Channel
      ..addJavaScriptChannel(
        'AjaxResponseMonitor',
        onMessageReceived: (JavaScriptMessage message) async {
          try {
            final responseData = jsonDecode(message.message);

            // Check if response contains required keys
            if (responseData['push_notification_secret'] != null &&
                responseData['customer_id'] != null) {

              String pushNotificationSecret = responseData['push_notification_secret'].toString();
              String customerId = responseData['customer_id'].toString();

              print("Found push notification data in AJAX response:");
              print("Customer ID: $customerId");
              print("Push Notification Secret: $pushNotificationSecret");

              // Register device with appropriate endpoint
              await _logicController.registerDeviceForNotifications(
                  customerId,
                  pushNotificationSecret,
                  url
              );
            }
          } catch (e) {
            print("Error parsing AJAX response: $e");
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _onPageStarted(),
          onPageFinished: (_) => _onPageFinished(),
          onWebResourceError: (error) => _onWebResourceError(error),
          onNavigationRequest: (request) {
            final url = request.url;

            // Check if it's a payment URL or external URL that should be opened externally
            if (url.contains('razorpay_order_id') ||
                url.contains('make-online-payment') ||
                url.startsWith('https://') && !url.contains(Uri.parse(this._getBaseUrl()).host)) {

              print('Intercepting external navigation: $url');
              openExternalUrl(url);
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
        ),
      );

    _controller = controller;
    notifyListeners();

    /// Load the URL
    await controller.loadRequest(Uri.parse(url));
  }

  String _getBaseUrl() {
    // Return your main app URL here
    return 'https://app.roadeeto.com'; // Adjust this to your main domain
  }

  /// Handle location request from WebView
  Future<void> _handleLocationRequest() async {
    try {
      Position? position = await getCurrentLocation();

      if (position != null) {
        // Send location back to WebView
        await _controller?.runJavaScript('''
          if (window.locationCallback) {
            window.locationCallback({
              latitude: ${position.latitude},
              longitude: ${position.longitude},
              accuracy: ${position.accuracy}
            });
          }
          
          // Also trigger geolocation success callback if exists
          if (window.geolocationSuccess) {
            window.geolocationSuccess({
              coords: {
                latitude: ${position.latitude},
                longitude: ${position.longitude},
                accuracy: ${position.accuracy}
              }
            });
          }
        ''');

        print('Location sent to WebView: ${position.latitude}, ${position.longitude}');
      } else {
        // Send error back to WebView
        await _controller?.runJavaScript('''
          if (window.locationError) {
            window.locationError({
              code: 1,
              message: "Location access denied or unavailable"
            });
          }
          
          // Also trigger geolocation error callback if exists
          if (window.geolocationError) {
            window.geolocationError({
              code: 1,
              message: "Location access denied or unavailable"
            });
          }
        ''');

        print('Failed to get location');
      }
    } catch (e) {
      print('Error handling location request: $e');

      // Send error back to WebView
      await _controller?.runJavaScript('''
        if (window.locationError) {
          window.locationError({
            code: 2,
            message: "Location error: $e"
          });
        }
      ''');
    }
  }

  /// Handle page started
  void _onPageStarted() {
    _isLoading = true;
    _hasError = false;
    notifyListeners();
  }

  void _onPageFinished() {
    _isLoading = false;

    _controller?.runJavaScriptReturningResult('document.cookie').then((cookies) {
      debugPrint('All Cookies: $cookies');
    }).catchError((error) {
      debugPrint('Error fetching cookies: $error');
    });

    // Fixed JavaScript injection with proper escaping and syntax
    _controller?.runJavaScript('''
(function() {
  console.log("🔍 AJAX Response Monitor initialized");
  
  // Add global function to manually open external URLs
  window.openExternalUrl = function(url) {
    console.log("🔗 Manual external URL request:", url);
    if (window.ManualExternalUrl) {
      ManualExternalUrl.postMessage(url);
    } else if (window.ExternalLinkOpener) {
      ExternalLinkOpener.postMessage(url);
    }
  };
  
  // Override navigator.geolocation.getCurrentPosition
  if (navigator.geolocation && navigator.geolocation.getCurrentPosition) {
    var originalGetCurrentPosition = navigator.geolocation.getCurrentPosition;
    
    navigator.geolocation.getCurrentPosition = function(success, error, options) {
      console.log("📍 Geolocation request intercepted");
      
      // Store callbacks globally for Flutter to access
      window.geolocationSuccess = success;
      window.geolocationError = error;
      
      // Request location from Flutter
      if (window.LocationChannel) {
        LocationChannel.postMessage('getCurrentLocation');
      } else {
        // Fallback to original method
        console.log("LocationChannel not available, using original method");
        originalGetCurrentPosition.call(this, success, error, options);
      }
    };
    
    console.log("📍 Geolocation override installed");
  }
  
  // Function to check and send response data
  var checkAndSendResponse = function(responseText, requestUrl) {
    requestUrl = requestUrl || '';
    try {
      var json = JSON.parse(responseText);
      console.log("📡 AJAX Response:", json);
      
      // Check for external_url (existing functionality)
      if (json.external_url) {
        console.log("🔗 External URL found:", json.external_url);
        if (window.ExternalLinkOpener) {
          ExternalLinkOpener.postMessage(json.external_url);
        }
      }
      
      // Check for payment URLs or any URL that should be opened externally
      if (json.payment_url || json.redirect_url) {
        var urlToOpen = json.payment_url || json.redirect_url;
        console.log("💳 Payment/Redirect URL found:", urlToOpen);
        window.openExternalUrl(urlToOpen);
      }
      
      // Check for push notification data
      if (json.push_notification_secret && json.customer_id) {
        console.log("🔔 Push notification data found!");
        console.log("👤 Customer ID:", json.customer_id);
        console.log("🔐 Push Secret:", json.push_notification_secret);
        if (window.AjaxResponseMonitor) {
          AjaxResponseMonitor.postMessage(JSON.stringify(json));
        }
      }
      
    } catch (e) {
      // Not JSON or parsing error - ignore silently for non-JSON responses
      if (responseText && responseText.trim().indexOf('{') === 0) {
        console.log("⚠️ Error parsing JSON response:", e);
      }
    }
  };

  // Override fetch API
  if (window.fetch) {
    var originalFetch = window.fetch;
    window.fetch = function() {
      var url = arguments[0];
      console.log("🌐 Fetch request to:", url);
      
      return originalFetch.apply(this, arguments).then(function(response) {
        var clonedResponse = response.clone();
        clonedResponse.text().then(function(responseText) {
          checkAndSendResponse(responseText, url);
        }).catch(function(e) {
          console.log("Error reading fetch response:", e);
        });
        return response;
      });
    };
  }

  // Override XMLHttpRequest
  if (window.XMLHttpRequest) {
    var originalXhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(data) {
      var xhr = this;
      console.log("📡 XHR request:", xhr.responseURL || 'unknown URL');
      
      xhr.addEventListener('load', function() {
        if (xhr.responseText) {
          checkAndSendResponse(xhr.responseText, xhr.responseURL);
        }
      });
      
      xhr.addEventListener('error', function() {
        console.log("❌ XHR error for:", xhr.responseURL);
      });
      
      originalXhrSend.apply(this, arguments);
    };
  }
  
  // Override jQuery AJAX if available
  if (window.jQuery && window.jQuery.ajax) {
    var originalJqueryAjax = window.jQuery.ajax;
    window.jQuery.ajax = function(options) {
      var originalSuccess = options.success;
      var originalComplete = options.complete;
      
      options.success = function(data, textStatus, jqXHR) {
        console.log("✅ jQuery AJAX success:", options.url);
        if (typeof data === 'object') {
          checkAndSendResponse(JSON.stringify(data), options.url);
        } else {
          checkAndSendResponse(data, options.url);
        }
        if (originalSuccess) {
          originalSuccess.apply(this, arguments);
        }
      };
      
      options.complete = function(jqXHR, textStatus) {
        if (jqXHR.responseText && !originalSuccess) {
          checkAndSendResponse(jqXHR.responseText, options.url);
        }
        if (originalComplete) {
          originalComplete.apply(this, arguments);
        }
      };
      
      return originalJqueryAjax.call(this, options);
    };
    console.log("✅ jQuery AJAX override installed");
  }
  
  // Override axios if available
  if (window.axios && window.axios.interceptors) {
    window.axios.interceptors.response.use(
      function (response) {
        console.log("✅ Axios response:", response.config.url);
        if (response.data) {
          checkAndSendResponse(JSON.stringify(response.data), response.config.url);
        }
        return response;
      },
      function (error) {
        console.log("❌ Axios error:", error.config ? error.config.url : 'unknown');
        return Promise.reject(error);
      }
    );
    console.log("✅ Axios interceptor installed");
  }
  
  console.log("🎯 All AJAX monitoring systems active!");
  console.log("📍 Location services ready!");
  console.log("🔗 External URL opener ready!");
  
})();
''');

    notifyListeners();
  }

  /// Handle web resource error
  void _onWebResourceError(WebResourceError error) {
    _isLoading = false;
    _hasError = true;
    _errorMessage = _getErrorMessage(error.errorType);
    notifyListeners();
  }

  /// Get custom error messages
  String _getErrorMessage(WebResourceErrorType? errorType) {
    if (errorType == null) {
      return 'Something went wrong.\nPlease check your internet connection and try again.';
    }

    switch (errorType) {
      case WebResourceErrorType.hostLookup:
        return 'Unable to connect to server.\nPlease check your internet connection.';
      case WebResourceErrorType.timeout:
        return 'Connection timeout.\nPlease try again.';
      case WebResourceErrorType.connect:
        return 'Connection failed.\nPlease check your internet connection.';
      default:
        return 'Something went wrong.\nPlease check your internet connection and try again.';
    }
  }

  /// Retry connection
  Future<void> retry(String url) async {
    clearError();
    await checkConnection(url);
  }

  /// Clear error state
  void clearError() {
    _hasError = false;
    _errorMessage = '';
    notifyListeners();
  }

  /// Reload current page
  Future<void> reload() async {
    if (_controller != null) {
      await _controller!.reload();
    }
  }

  /// Go back
  Future<void> goBack() async {
    if (_controller != null && await _controller!.canGoBack()) {
      await _controller!.goBack();
    }
  }

  /// Go forward
  Future<void> goForward() async {
    if (_controller != null && await _controller!.canGoForward()) {
      await _controller!.goForward();
    }
  }

  /// Load new URL
  Future<void> loadUrl(String url) async {
    if (_controller != null) {
      await _controller!.loadRequest(Uri.parse(url));
    }
  }

  /// Dispose resources
  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }
}