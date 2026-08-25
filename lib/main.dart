import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'services/onesignal_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Custom Status Bar Styling
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0F172A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const EkopiApp());
}

class EkopiApp extends StatelessWidget {
  const EkopiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EKOPI KALTENG',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFF59E0B),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorSchemeSeed: const Color(0xFFF59E0B),
        brightness: Brightness.dark,
      ),
      home: const EkopiWebViewScreen(),
    );
  }
}

class EkopiWebViewScreen extends StatefulWidget {
  const EkopiWebViewScreen({super.key});

  static const String defaultUrl = 'https://ekopi-poldakalteng.com';
  static const String configApiUrl = 'https://ekopi-poldakalteng.com/api/app-config';
  static const String backupConfigUrl = 'https://raw.githubusercontent.com/projectnya-noval/ekopi-kalteng-mobile/main/app-config.json';
  static const String backupWebConfigUrl = 'https://raw.githubusercontent.com/projectnya-noval/ekopi-kalteng/main/app-config.json';

  @override
  State<EkopiWebViewScreen> createState() => _EkopiWebViewScreenState();
}

class _EkopiWebViewScreenState extends State<EkopiWebViewScreen> {
  late final WebViewController _controller;
  int _loadingProgress = 0;
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  bool _verificationDialogShown = false;
  String _targetUrl = EkopiWebViewScreen.defaultUrl;
  String _appName = 'EKOPI KALTENG';
  String _appSubName = 'e-Konseling Psikologi Biro SDM';

  @override
  void initState() {
    super.initState();
    _initOneSignal();
    _requestAppPermissions();
    _initWebViewController();
    _fetchAndApplyDynamicConfig();
  }

  @override
  void dispose() {
    OneSignalService.instance.removePushSubscriptionObserver(_onPushSubscriptionChanged);
    super.dispose();
  }

  /// Memuat & Mengaplikasikan Konfigurasi URL & Identitas Dinamis (Dengan Dual Fail-Safe Server & GitHub Backup)
  Future<void> _fetchAndApplyDynamicConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load cached URL & app settings first if available
      final cachedUrl = prefs.getString('cached_target_url');
      if (cachedUrl != null && cachedUrl.isNotEmpty && cachedUrl != _targetUrl) {
        _targetUrl = cachedUrl;
        _controller.loadRequest(Uri.parse(_targetUrl));
      }

      final cachedAppName = prefs.getString('cached_app_name');
      final cachedAppSubName = prefs.getString('cached_app_sub_name');
      if (cachedAppName != null && cachedAppName.isNotEmpty) {
        _appName = cachedAppName;
      }
      if (cachedAppSubName != null && cachedAppSubName.isNotEmpty) {
        _appSubName = cachedAppSubName;
      }

      String? remoteUrl;
      Map<String, dynamic>? remoteData;

      // 1. Coba Server Utama (Query tabel app_settings)
      try {
        final response = await http
            .get(Uri.parse(EkopiWebViewScreen.configApiUrl))
            .timeout(const Duration(seconds: 3));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data != null && data['target_url'] != null) {
            remoteUrl = data['target_url'].toString().trim();
            remoteData = data;
          }
        }
      } catch (e) {
        debugPrint('Primary server config failed, switching to GitHub backup config... $e');
      }

      // 2. Fail-Safe Backup: Jika Server Utama Mati/Expired, Ambil dari GitHub Raw JSON (Mobile / Web Repo)
      if (remoteUrl == null || remoteUrl.isEmpty) {
        for (final backupUrl in [
          EkopiWebViewScreen.backupConfigUrl,
          EkopiWebViewScreen.backupWebConfigUrl,
        ]) {
          try {
            final backupResponse = await http
                .get(Uri.parse(backupUrl))
                .timeout(const Duration(seconds: 3));

            if (backupResponse.statusCode == 200) {
              final data = json.decode(backupResponse.body);
              if (data != null && data['target_url'] != null) {
                remoteUrl = data['target_url'].toString().trim();
                remoteData = data;
                if (remoteUrl.isNotEmpty) break;
              }
            }
          } catch (e) {
            debugPrint('GitHub backup config fetch notice: $e');
          }
        }
      }

      if (remoteData != null) {
        if (remoteData['app_name'] != null) {
          final name = remoteData['app_name'].toString().trim();
          if (name.isNotEmpty) {
            _appName = name;
            await prefs.setString('cached_app_name', name);
          }
        }
        if (remoteData['app_sub_name'] != null) {
          final sub = remoteData['app_sub_name'].toString().trim();
          if (sub.isNotEmpty) {
            _appSubName = sub;
            await prefs.setString('cached_app_sub_name', sub);
          }
        }
        if (mounted) setState(() {});
      }

      if (remoteUrl != null && remoteUrl.isNotEmpty && remoteUrl != _targetUrl) {
        _targetUrl = remoteUrl;
        await prefs.setString('cached_target_url', remoteUrl);
        if (mounted) {
          _controller.loadRequest(Uri.parse(_targetUrl));
        }
      }
    } catch (e) {
      debugPrint('Config check error: $e');
    }
  }

  /// Inisialisasi OneSignal SDK & Push Subscription Observer
  Future<void> _initOneSignal() async {
    await OneSignalService.instance.init();
    OneSignalService.instance.addPushSubscriptionObserver(_onPushSubscriptionChanged);

    // Periksa status subscription saat pertama kali diinisialisasi
    final currentId = OneSignalService.instance.pushSubscriptionId;
    _checkAndShowVerificationDialog(currentId);
  }

  void _onPushSubscriptionChanged(OSPushSubscriptionChangedState state) {
    _checkAndShowVerificationDialog(state.current.id);
  }

  void _checkAndShowVerificationDialog(String? id) {
    if (_verificationDialogShown) return;

    // Verifikasi ID subscription asli dari server OneSignal (bukan local- ID)
    if (id != null && id.isNotEmpty && !id.startsWith('local-')) {
      _verificationDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showVerificationDialog();
      });
    }
  }

  void _showVerificationDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'Your OneSignal SDK integration is complete!',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        content: const Text(
          'You can now send Push Notifications & In-App Messages through OneSignal. Tap below to enable push notifications.',
          style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              OneSignalService.instance.requestPushPermission();
            },
            child: const Text(
              'Got it',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  /// Request Android Runtime Permissions for Camera, Storage & Location
  Future<void> _requestAppPermissions() async {
    try {
      await [
        Permission.camera,
        Permission.microphone,
        Permission.storage,
        Permission.photos,
        Permission.locationWhenInUse,
      ].request();
    } catch (e) {
      debugPrint('Permission request error: $e');
    }
  }

  /// Initialize WebViewController with platform-specific options
  void _initWebViewController() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 14; Mobile) EkopiFlutterApp/1.0 (Android APK)')
      ..setBackgroundColor(const Color(0xFF0F172A))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress;
              });
            }
          },
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _hasError = false;
                _errorMessage = '';
              });
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _loadingProgress = 100;
              });
            }
          },
          onWebResourceError: (WebResourceError error) {
            if ((error.isForMainFrame ?? true) && mounted) {
              setState(() {
                _hasError = true;
                _isLoading = false;
                _errorMessage = error.description;
              });
            }
          },
          onNavigationRequest: (NavigationRequest request) async {
            final Uri uri = Uri.parse(request.url);

            // Handle external schemes (WhatsApp, Phone Call, Email, Maps, etc.)
            if (!['http', 'https'].contains(uri.scheme) ||
                request.url.contains('wa.me') ||
                request.url.contains('api.whatsapp.com')) {
              try {
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                  return NavigationDecision.prevent;
                }
              } catch (e) {
                debugPrint('Could not launch external URL: ${request.url}');
              }
            }

            return NavigationDecision.navigate;
          },
        ),
      );

    // Android specific WebView settings (Geolocation, File Access, DomStorage)
    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      androidController.setOnPlatformPermissionRequest((request) {
        request.grant();
      });
    }

    controller.loadRequest(Uri.parse(_targetUrl));
    _controller = controller;
  }

  /// Reload webpage
  Future<void> _reloadPage() async {
    setState(() {
      _hasError = false;
      _isLoading = true;
    });
    await _controller.reload();
  }

  /// Reset to Home URL
  void _goToHome() {
    setState(() {
      _hasError = false;
      _isLoading = true;
    });
    _controller.loadRequest(Uri.parse(_targetUrl));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;

        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else {
          if (context.mounted) {
            final shouldExit = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                title: const Row(
                  children: [
                    Icon(Icons.exit_to_app, color: Color(0xFFF59E0B)),
                    SizedBox(width: 10),
                    Text(
                      'Keluar Aplikasi?',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                content: const Text(
                  'Apakah Anda yakin ingin keluar dari aplikasi e-KOPI Polda Kalteng?',
                  style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text(
                      'Batal',
                      style: TextStyle(color: Color(0xFF94A3B8)),
                    ),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: const Color(0xFF0F172A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text(
                      'Ya, Keluar',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            );

            if (shouldExit == true) {
              SystemNavigator.pop();
            }
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: AppBar(
            backgroundColor: const Color(0xFF0F172A),
            elevation: 0,
            titleSpacing: 16,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0x26F59E0B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0x4DF59E0B),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.asset(
                      'assets/logo-psikologi.png',
                      width: 24,
                      height: 24,
                      fit: BoxFit.contain,
                      errorBuilder: (ctx, err, stack) => const Icon(
                        Icons.psychology,
                        color: Color(0xFFF59E0B),
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _appName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _appSubName,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFFCBD5E1), size: 20),
                tooltip: 'Muat Ulang',
                onPressed: _reloadPage,
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFFCBD5E1), size: 20),
                color: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                onSelected: (value) async {
                  if (value == 'home') {
                    _goToHome();
                  } else if (value == 'reload') {
                    _reloadPage();
                  } else if (value == 'clear_cache') {
                    await _controller.clearCache();
                    await _reloadPage();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Cache berhasil dibersihkan'),
                          backgroundColor: Color(0xFFF59E0B),
                        ),
                      );
                    }
                  } else if (value == 'open_browser') {
                    final currentUrl = await _controller.currentUrl();
                    final uri = Uri.parse(currentUrl ?? _targetUrl);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'home',
                    child: Row(
                      children: [
                        Icon(Icons.home, color: Color(0xFFF59E0B), size: 18),
                        SizedBox(width: 10),
                        Text('Halaman Utama', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'reload',
                    child: Row(
                      children: [
                        Icon(Icons.refresh, color: Colors.blueAccent, size: 18),
                        SizedBox(width: 10),
                        Text('Muat Ulang Halaman', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear_cache',
                    child: Row(
                      children: [
                        Icon(Icons.cleaning_services, color: Colors.amber, size: 18),
                        SizedBox(width: 10),
                        Text('Bersihkan Cache', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'open_browser',
                    child: Row(
                      children: [
                        Icon(Icons.open_in_browser, color: Color(0xFF10B981), size: 18),
                        SizedBox(width: 10),
                        Text('Buka di Browser', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Linear Loading Indicator
              if (_isLoading && !_hasError)
                LinearProgressIndicator(
                  value: _loadingProgress / 100.0,
                  backgroundColor: const Color(0xFF1E293B),
                  color: const Color(0xFFF59E0B),
                  minHeight: 3,
                ),

              // Main Body Content
              Expanded(
                child: _hasError
                    ? _buildErrorScreen()
                    : WebViewWidget(controller: _controller),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Offline / Network / Maintenance Error View Placeholder
  Widget _buildErrorScreen() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Logo & Badge Header
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: const Color(0x1AF59E0B),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0x4DF59E0B),
                      width: 2,
                    ),
                  ),
                ),
                Image.asset(
                  'assets/logo-psikologi.png',
                  width: 58,
                  height: 58,
                  fit: BoxFit.contain,
                  errorBuilder: (ctx, err, stack) => const Icon(
                    Icons.signal_wifi_connected_no_internet_4_rounded,
                    color: Color(0xFFF59E0B),
                    size: 48,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Badge Warning
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x26F59E0B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x66F59E0B)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 14),
                  SizedBox(width: 6),
                  Text(
                    'KONEKSI TERPUTUS / SERVER DOWN',
                    style: TextStyle(
                      color: Color(0xFFF59E0B),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Title
            const Text(
              'Gagal Memuat Layanan e-KOPI',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 10),

            // Subtitle Description
            const Text(
              'Aplikasi tidak dapat terhubung ke server target. Pastikan jaringan internet ponsel Anda terhubung dengan stabil atau server sedang dalam pemeliharaan berkala.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 12.5,
                height: 1.5,
              ),
            ),

            // Error Details Card
            if (_errorMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0x1AE11D48),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x4DE11D48)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFFFB7185), size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _errorMessage,
                        style: const TextStyle(
                          color: Color(0xFFFB7185),
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 32),

            // Primary Action Button (Coba Lagi)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B),
                  foregroundColor: const Color(0xFF0F172A),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 4,
                ),
                onPressed: () async {
                  await _fetchAndApplyDynamicConfig();
                  await _reloadPage();
                },
                icon: const Icon(Icons.refresh_rounded, size: 20),
                label: const Text(
                  'MUAT ULANG & CEK KONEKSI',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Secondary Action Button (Buka di Browser)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFCBD5E1),
                  side: const BorderSide(color: Color(0xFF334155), width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () async {
                  final uri = Uri.parse(_targetUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: const Text(
                  'BUKA DI BROWSER EKSTERNAL',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
