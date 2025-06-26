import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'package:app_links/app_links.dart';
import 'package:roadeeto/splash_screen.dart';
import 'controller/network_connection_controller.dart';
import 'firebase_options.dart';
import 'home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _appLinks = AppLinks();
  Uri? _initialLink;

  @override
  void initState() {
    super.initState();
    _handleDeepLinks();
  }

  void _handleDeepLinks() async {
    // Handle initial link
    _initialLink = await _appLinks.getInitialLink();
    if (_initialLink != null) {
      _navigateToDeepLink(_initialLink!);
    }

    // Listen for subsequent links
    _appLinks.uriLinkStream.listen((Uri? uri) {
      if (uri != null) {
        _navigateToDeepLink(uri);
      }
    });
  }

  void _navigateToDeepLink(Uri uri) {
    final url = uri.toString();

    // Example: If your URI is roadeeto://cart or https://app.roadeeto.com/cart
    if (url.contains("/cart")) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => WebViewScreen(url: "https://app.roadeeto.com/cart"),
        ),
      );
    } else {
      // Default fallback
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => WebViewScreen(url: "https://app.roadeeto.com/home"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NetworkConnectionController()),
      ],
      child: MaterialApp(
        title: 'Roadeeto App',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.amber,
          scaffoldBackgroundColor: Colors.white,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.amber,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        home: SplashScreen(), // This will change later depending on the deep link
      ),
    );
  }
}
