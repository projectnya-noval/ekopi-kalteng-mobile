import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
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
  bool _verificationDialogShown = false;
  String _targetUrl = EkopiWebViewScreen.defaultUrl;
  String _appName = 'EKOPI KALTENG';
  String _appSubName = 'e-Konseling Psikologi Biro SDM';

  // Real-time Internet Connectivity & Loading States
  bool _isOffline = false;
  bool _isCheckingConnection = false;
  bool _hasInitialLoaded = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _connectivityPingTimer;

  @override
  void initState() {
    super.initState();
    _initOneSignal();
    _requestAppPermissions();
    _initWebViewController();
    _initRealtimeConnectivity();
    _fetchAndApplyDynamicConfig();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _connectivityPingTimer?.cancel();
    OneSignalService.instance.removePushSubscriptionObserver(_onPushSubscriptionChanged);
    super.dispose();
  }

  /// Inisialisasi Real-time Connectivity Monitor & Periodic Health Ping
  void _initRealtimeConnectivity() {
    // 1. Cek Koneksi Pertama Kali Saat Aplikasi Dibuka
    _checkInternetConnectivity();

    // 2. Real-time Stream Listener dari OS Android (Bila status WiFi/Mobile Data Berubah)
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      debugPrint('📡 [REALTIME CONNECTIVITY CHANGE]: $results');
      _checkInternetConnectivity();
    });

    // 3. Periodic Health Check (Cek ulang koneksi setiap 4 detik bila sedang offline)
    _connectivityPingTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_isOffline) {
        _checkInternetConnectivity();
      }
    });
  }

  /// Memeriksa Koneksi Internet secara Aktif (Dengan DNS/HTTP Ping Real-Time)
  Future<void> _checkInternetConnectivity({bool forceReload = false}) async {
    if (_isCheckingConnection) return;
    _isCheckingConnection = true;

    try {
      final connectivityResults = await Connectivity().checkConnectivity();
      final hasNetworkInterface = connectivityResults.any((result) =>
          result == ConnectivityResult.mobile ||
          result == ConnectivityResult.wifi ||
          result == ConnectivityResult.ethernet);

      bool isInternetReachable = false;

      if (hasNetworkInterface) {
        try {
          final result = await InternetAddress.lookup('ekopi-poldakalteng.com')
              .timeout(const Duration(seconds: 3));
          if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
            isInternetReachable = true;
          }
        } catch (_) {
          try {
            final result = await InternetAddress.lookup('google.com')
                .timeout(const Duration(seconds: 3));
            if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
              isInternetReachable = true;
            }
          } catch (_) {
            isInternetReachable = false;
          }
        }
      }

      if (mounted) {
        final wasOffline = _isOffline;
        setState(() {
          _isOffline = !isInternetReachable;
          if (_isOffline) {
            _hasError = true;
          } else {
            _hasError = false;
          }
        });

        // LOGIKA AUTOMATIC RECOVERY: Jika sebelumnya offline dan sekarang internet AKTIF kembali -> Tutup overlay & muat ulang webview!
        if ((wasOffline && isInternetReachable) || (forceReload && isInternetReachable)) {
          debugPrint('🌐 [INTERNET RESTORED]: Reloading WebView automatically...');
          _controller.loadRequest(Uri.parse(_targetUrl));
        }
      }
    } catch (e) {
      debugPrint('Connectivity check error: $e');
    } finally {
      _isCheckingConnection = false;
    }
  }

  /// Memuat & Mengaplikasikan Konfigurasi URL & Identitas Dinamis
  Future<void> _fetchAndApplyDynamicConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final cachedUrl = prefs.getString('cached_target_url');
      if (cachedUrl != null && cachedUrl.isNotEmpty && cachedUrl != _targetUrl) {
        _targetUrl = cachedUrl;
        if (!_isOffline) {
          _controller.loadRequest(Uri.parse(_targetUrl));
        }
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
        if (mounted && !_isOffline) {
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

    final currentId = OneSignalService.instance.pushSubscriptionId;
    _checkAndShowVerificationDialog(currentId);
  }

  void _onPushSubscriptionChanged(OSPushSubscriptionChangedState state) {
    _checkAndShowVerificationDialog(state.current.id);
  }

  void _checkAndShowVerificationDialog(String? id) {
    if (_verificationDialogShown) return;

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
        title: const Row(
          children: [
            Icon(Icons.verified_user_rounded, color: Color(0xFF10B981)),
            SizedBox(width: 10),
            Text(
              'Notifikasi Aktif',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: const Text(
          'Aplikasi e-KOPI Polda Kalteng berhasil terhubung ke server Notifikasi OS.',
          style: TextStyle(
            color: Color(0xFFCBD5E1),
            fontSize: 13,
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Mengerti', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Request Android Runtime Permissions for Notifications, Camera, Storage & Location
  Future<void> _requestAppPermissions() async {
    try {
      await [
        Permission.notification,
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

    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      androidController.setOnShowFileSelector((FileSelectorParams fileParams) async {
        final ImagePicker picker = ImagePicker();
        
        final source = await showModalBottomSheet<ImageSource>(
          context: context,
          backgroundColor: const Color(0xFF1E293B),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF475569),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Pilih Sumber Swafoto / Dokumen',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0x26F59E0B),
                      child: Icon(Icons.camera_alt, color: Color(0xFFF59E0B)),
                    ),
                    title: const Text(
                      'Kamera (Swafoto Langsung)',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'Ambil foto swafoto langsung dari kamera HP',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    ),
                    onTap: () => Navigator.pop(ctx, ImageSource.camera),
                  ),
                  ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0x263B82F6),
                      child: Icon(Icons.photo_library, color: Color(0xFF3B82F6)),
                    ),
                    title: const Text(
                      'Galeri HP / File Foto',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: const Text(
                      'Pilih foto swafoto yang sudah ada di galeri HP',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    ),
                    onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                  ),
                ],
              ),
            ),
          ),
        );

        if (source != null) {
          final XFile? file = await picker.pickImage(
            source: source,
            maxWidth: 1920,
            maxHeight: 1920,
            imageQuality: 85,
          );
          if (file != null) {
            return [Uri.file(file.path).toString()];
          }
        }
        return [];
      });
    }

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
                if (!_isOffline) {
                  _hasError = false;
                }
              });
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _loadingProgress = 100;
                _hasInitialLoaded = true; // Tandai WebView telah berhasil dimuat
              });
            }
          },
          onWebResourceError: (WebResourceError error) {
            if ((error.isForMainFrame ?? true) && mounted) {
              setState(() {
                _hasError = true;
                _isOffline = true;
                _isLoading = false;
              });
            }
          },
          onNavigationRequest: (NavigationRequest request) async {
            final Uri uri = Uri.parse(request.url);

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

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller;
    
    // Hanya muat URL jika internet aktif saat pertama kali dibuka
    if (!_isOffline) {
      _controller.loadRequest(Uri.parse(_targetUrl));
    }
  }

  Future<void> _reloadPage() async {
    await _checkInternetConnectivity(forceReload: true);
  }

  Future<void> _goToHome() async {
    await _checkInternetConnectivity();
    if (!_isOffline) {
      _controller.loadRequest(Uri.parse(_targetUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
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
                    Icon(Icons.exit_to_app_rounded, color: Color(0xFFF59E0B)),
                    SizedBox(width: 10),
                    Text(
                      'Keluar Aplikasi',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
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
                        Icon(Icons.refresh, color: Color(0xFF38BDF8), size: 18),
                        SizedBox(width: 10),
                        Text('Refresh Halaman', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear_cache',
                    child: Row(
                      children: [
                        Icon(Icons.cleaning_services, color: Color(0xFFFB7185), size: 18),
                        SizedBox(width: 10),
                        Text('Bersihkan Cache', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'open_browser',
                    child: Row(
                      children: [
                        Icon(Icons.open_in_browser, color: Color(0xFFA7F3D0), size: 18),
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
              if (_isLoading && !_hasError && !_isOffline)
                LinearProgressIndicator(
                  value: _loadingProgress / 100.0,
                  backgroundColor: const Color(0xFF1E293B),
                  color: const Color(0xFFF59E0B),
                  minHeight: 3,
                ),

              // Main Content: Stack antara WebView, Screen Placeholder, dan Full Screen Overlay Popup
              Expanded(
                child: Stack(
                  children: [
                    // LOGIKA 1: Screen Placeholder jika pertama kali buka app tanpa koneksi
                    (_isOffline && !_hasInitialLoaded)
                        ? _buildInitialOfflinePlaceholder()
                        : WebViewWidget(controller: _controller),

                    // LOGIKA 2: Full-screen Popup Overlay yang menutupi WebView saat internet mati KETIKA WebView SEDANG DIBUKA
                    if (_isOffline && _hasInitialLoaded)
                      _buildLiveOfflineOverlayPopup(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// LOGIKA 1: Screen Placeholder "Koneksi internet Anda sedang tidak aktif" (Saat Pertama Kali Buka App Tanpa Internet)
  Widget _buildInitialOfflinePlaceholder() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 20),
            
            // Icon Wireless Offline
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: const Color(0x1AE11D48),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0x4DE11D48),
                      width: 2,
                    ),
                  ),
                ),
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(
                    color: Color(0x33E11D48),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.wifi_off_rounded,
                    color: Color(0xFFFB7185),
                    size: 44,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Badge Status Offline
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0x26E11D48),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x66E11D48)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.signal_wifi_connected_no_internet_4_rounded, color: Color(0xFFFB7185), size: 14),
                  SizedBox(width: 6),
                  Text(
                    'STATUS KONEKSI: OFFLINE',
                    style: TextStyle(
                      color: Color(0xFFFB7185),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Main Title
            const Text(
              'Koneksi internet Anda sedang tidak aktif',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 10),

            // Subtitle Description
            const Text(
              'Aplikasi e-KOPI Polda Kalteng tidak dapat terhubung ke server. Silakan aktifkan koneksi Wi-Fi atau Paket Data seluler di perangkat Anda untuk melanjutkan.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),

            // Auto-Monitoring Realtime Badge Spinner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _isCheckingConnection ? const Color(0xFFF59E0B) : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isCheckingConnection
                        ? 'Mencoba menghubungkan kembali...'
                        : 'Memantau jaringan otomatis...',
                    style: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Primary Action Button (Muat Ulang / Cek KoneKSI)
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
                onPressed: () => _checkInternetConnectivity(forceReload: true),
                icon: const Icon(Icons.refresh_rounded, size: 20),
                label: const Text(
                  'CEK KONEKSI & MUAT ULANG',
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

  /// LOGIKA 2: Full-Screen Popup Overlay yang Menutupi Seluruh Screen WebView Saat Koneksi Mati KETIKA WebView Sedang Dibuka
  Widget _buildLiveOfflineOverlayPopup() {
    return Positioned.fill(
      child: AbsorbPointer(
        absorbing: true, // Menutup interaksi & klik pada webview di bawahnya 100%
        child: Container(
          color: const Color(0xED0F172A), // Background Gelap Transparan 93% Menutupi Layar WebView
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0x66E11D48), width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header Alert Badge Icon
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0x26E11D48),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0x66E11D48), width: 2),
                    ),
                    child: const Icon(
                      Icons.signal_wifi_connected_no_internet_4_rounded,
                      color: Color(0xFFFB7185),
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Warning Title
                  const Text(
                    'Koneksi internet tidak stabil, periksa koneksi internet anda',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Warning Message Text
                  const Text(
                    'Perangkat Anda kehilangan sambungan jaringan. Layar dikunci sementara hingga koneksi internet terhubung kembali.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Realtime Auto-Reconnect Monitoring Spinner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF59E0B)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _isCheckingConnection
                              ? 'Mencoba menyambungkan kembali...'
                              : 'Memantau jaringan otomatis secara realtime...',
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Action Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: const Color(0xFF0F172A),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => _checkInternetConnectivity(forceReload: true),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text(
                        'PERIKSA KONEKSI SEKARANG',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
