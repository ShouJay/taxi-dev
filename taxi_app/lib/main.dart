import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config/app_config.dart';
import 'services/mqtt_manager.dart';
import 'services/shadow_sync_service.dart';
import 'services/download_manager.dart';
import 'services/location_service.dart';
import 'managers/playback_manager.dart';
import 'models/shadow_playlist.dart';
import 'models/play_ad_command.dart';
import 'screens/main_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const TaxiApp());
}

class TaxiApp extends StatelessWidget {
  const TaxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taxi 廣告播放系統',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      home: const AppContainer(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppContainer extends StatefulWidget {
  const AppContainer({super.key});

  @override
  State<AppContainer> createState() => _AppContainerState();
}

class _AppContainerState extends State<AppContainer>
    with WidgetsBindingObserver {
  late MqttManager _mqttManager;
  late ShadowSyncService _shadowSync;
  late DownloadManager _downloadManager;
  late PlaybackManager _playbackManager;
  late LocationService _locationService;

  bool _showSettings = false;
  bool _isInitialized = false;
  bool _isAdminMode = false;
  String _deviceRole = AppConfig.defaultDeviceRole;
  Position? _latestPosition;
  DateTime? _lastLocationSentTime;
  EmergencyState _emergencyState = EmergencyState();
  bool _wasInEmergencyPlayback = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      print('🚀 初始化 MQTT 車載 App v2.0.0...');
      final prefs = await SharedPreferences.getInstance();

      final deviceId =
          prefs.getString(AppConfig.deviceIdKey) ?? AppConfig.defaultDeviceId;
      await prefs.setString(AppConfig.deviceIdKey, deviceId);

      final brokerHost =
          prefs.getString(AppConfig.mqttBrokerHostKey) ??
          AppConfig.mqttBrokerHost;
      final adminMode = prefs.getBool(AppConfig.adminModeKey) ?? false;
      _deviceRole =
          prefs.getString(AppConfig.deviceRoleKey) ??
          AppConfig.defaultDeviceRole;

      _mqttManager = MqttManager(deviceId: deviceId, brokerHost: brokerHost);
      _downloadManager = DownloadManager(baseUrl: AppConfig.apiBaseUrl);
      _playbackManager = PlaybackManager(downloadManager: _downloadManager);
      _shadowSync = ShadowSyncService(
        mqttManager: _mqttManager,
        downloadManager: _downloadManager,
      );
      _locationService = LocationService(mqttManager: _mqttManager);

      _setupMqttHandlers();
      _setupShadowHandlers();
      _setupLocationCallbacks();

      await _mqttManager.connect();
      await _locationService.start();
      await _playbackManager.startAutoPlay();

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isAdminMode = adminMode;
          _latestPosition = _locationService.currentPosition;
          _lastLocationSentTime = _locationService.lastLocationSentTime;
        });
      }
      print('✅ 初始化完成');
    } catch (e) {
      print('❌ 初始化失敗: $e');
    }
  }

  void _setupMqttHandlers() {
    _mqttManager.onConnected = () {
      _locationService.sendCurrentLocation();
      _shadowSync.publishReportedNow();
    };

    _mqttManager.onDesiredPlaylist = (desired) {
      _shadowSync.handleDesired(desired);
    };

    _mqttManager.onEmergencyMessage = (state) {
      _handleEmergencyState(state);
    };
  }

  void _setupShadowHandlers() {
    _shadowSync.onCampaignReady = (campaignId, playlist) async {
      await _playbackManager.startCampaignPlayback(
        campaignId: campaignId,
        playlist: playlist,
      );
    };

    _shadowSync.onRevertToLocal = () async {
      await _playbackManager.revertToLocalPlayback();
    };

    _shadowSync.onOverridePlay = (command) async {
      await _handlePlayAdCommand(command);
    };
  }

  void _setupLocationCallbacks() {
    _locationService.onLocationUpdate = (position) {
      if (!mounted) return;
      setState(() {
        _latestPosition = position;
        _lastLocationSentTime = _locationService.lastLocationSentTime;
      });
    };
  }

  Future<void> _handleEmergencyState(EmergencyState state) async {
    if (state.type == 'stats_update') {
      if (mounted) {
        setState(() {
          _emergencyState = EmergencyState(
            isAlarmActive: _emergencyState.isAlarmActive,
            marqueeText: _emergencyState.marqueeText,
            emergencyVideo: _emergencyState.emergencyVideo,
            qrScanCount: state.qrScanCount,
          );
        });
      }
      return;
    }

    if (state.type != null &&
        state.type != 'system_state' &&
        state.type != 'system_state_update') {
      return;
    }

    if (!mounted) return;
    setState(() {
      _emergencyState = state;
    });

    if (_deviceRole == 'SCREEN_B') {
      if (state.isAlarmActive) {
        _wasInEmergencyPlayback = true;
        final filename = state.emergencyVideo;
        final exists = await _downloadManager.isVideoExists(filename);
        if (exists) {
          await _playbackManager.insertAd(
            videoFilename: filename,
            advertisementId: 'emergency-$filename',
            advertisementName: '緊急警報',
            trigger: 'emergency',
            isOverride: true,
          );
        } else {
          print('⚠️ 緊急影片未預載: $filename');
        }
      } else if (_wasInEmergencyPlayback) {
        _wasInEmergencyPlayback = false;
        await _playbackManager.revertToLocalPlayback();
      }
    }
  }

  Future<void> _handlePlayAdCommand(PlayAdCommand command) async {
    final exists = await _downloadManager.isVideoExists(command.videoFilename);
    if (!exists) {
      print('⚠️ 影片不存在，等待 shadow 同步下載: ${command.videoFilename}');
      return;
    }

    await _playbackManager.insertAd(
      videoFilename: command.videoFilename,
      advertisementId: command.advertisementId,
      advertisementName: command.advertisementName,
      isOverride: command.isOverride,
      trigger: command.trigger,
      campaignId: command.campaignId,
    );
  }

  Future<void> _updateAdminMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.adminModeKey, value);
    if (!mounted) return;
    setState(() => _isAdminMode = value);
  }

  Future<void> _updateDeviceRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.deviceRoleKey, role);
    if (!mounted) return;
    setState(() => _deviceRole = role);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('初始化中...', style: TextStyle(fontSize: 18)),
            ],
          ),
        ),
      );
    }

    return _showSettings
        ? SettingsScreen(
            mqttManager: _mqttManager,
            playbackManager: _playbackManager,
            downloadManager: _downloadManager,
            locationService: _locationService,
            isAdminMode: _isAdminMode,
            deviceRole: _deviceRole,
            onAdminModeChanged: _updateAdminMode,
            onDeviceRoleChanged: _updateDeviceRole,
            onBack: () => setState(() => _showSettings = false),
          )
        : MainScreen(
            playbackManager: _playbackManager,
            downloadManager: _downloadManager,
            isAdminMode: _isAdminMode,
            deviceRole: _deviceRole,
            emergencyState: _emergencyState,
            latestPosition: _latestPosition,
            lastLocationSentTime: _lastLocationSentTime,
            mqttConnected: _mqttManager.isConnected,
            onSettingsRequested: () => setState(() => _showSettings = true),
          );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_mqttManager.isConnected) {
      _mqttManager.connect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mqttManager.dispose();
    _downloadManager.dispose();
    _playbackManager.dispose();
    _locationService.dispose();
    super.dispose();
  }
}
