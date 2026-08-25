import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart'; // 💡 [Shorebird] 引用套件
import 'package:restart_app/restart_app.dart'; // 💡 [Shorebird] 引用軟重啟套件
import 'package:taxi_app/services/geofence_manager.dart';
import 'config/app_config.dart';
import 'models/download_info.dart';
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
  AppConfig.validate();
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
  late GeofenceManager _geofenceManager;

  //自動更新
  final _shorebirdCodePush = ShorebirdCodePush();
  Timer? _shorebirdTimer;
  bool _isPatchReadyToInstall = false;

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
      print('🚀 初始化 MQTT 車載 熱補丁OK版本App v2.0.0...');
      final prefs = await SharedPreferences.getInstance();

      final deviceId =
          prefs.getString(AppConfig.deviceIdKey) ?? AppConfig.defaultDeviceId;
      await prefs.setString(AppConfig.deviceIdKey, deviceId);

      final savedBrokerHost = prefs.getString(AppConfig.mqttBrokerHostKey);
      final brokerHost =
          savedBrokerHost == null ||
              AppConfig.isLegacyLocalMqttHost(savedBrokerHost)
          ? AppConfig.mqttBrokerHost
          : savedBrokerHost;
      if (savedBrokerHost != brokerHost) {
        await prefs.setString(AppConfig.mqttBrokerHostKey, brokerHost);
      }
      final adminMode = prefs.getBool(AppConfig.adminModeKey) ?? false;
      _deviceRole =
          prefs.getString(AppConfig.deviceRoleKey) ??
          AppConfig.defaultDeviceRole;

      final savedApiUrl = prefs.getString(AppConfig.apiServerUrlKey);
      final apiBaseUrl = savedApiUrl ?? AppConfig.apiBaseUrl;

      _mqttManager = MqttManager(deviceId: deviceId, brokerHost: brokerHost);
      _downloadManager = DownloadManager(baseUrl: apiBaseUrl);
      _playbackManager = PlaybackManager(downloadManager: _downloadManager);
      _shadowSync = ShadowSyncService(
        mqttManager: _mqttManager,
        downloadManager: _downloadManager,
        playbackManager: _playbackManager, // 💡 補上這個參數
      );
      _locationService = LocationService(mqttManager: _mqttManager);

      _setupMqttHandlers();
      _setupShadowHandlers();
      _setupLocationCallbacks();
      _initGeofence();

      await _mqttManager.connect();
      await _locationService.start();
      await _playbackManager.startAutoPlay();

      //啟動熱補丁輪詢與檢查機制
      _initShorebirdPolling();

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

  // 💡 [Shorebird] 初始化輪詢與定時器
  void _initShorebirdPolling() {
    // 啟動 App 後在背景先檢查一次
    _checkForShorebirdUpdates();

    // 針對常駐車載平板，設定每 4 小時自動檢查一次雲端 Patch
    _shorebirdTimer = Timer.periodic(const Duration(hours: 4), (_) {
      _checkForShorebirdUpdates();
    });
  }

  // 💡 [Shorebird] 背景檢查與下載 Patch
  Future<void> _checkForShorebirdUpdates() async {
    try {
      print('🦋 [Shorebird] 開始檢查熱補丁更新...');

      final currentPatch = await _shorebirdCodePush.currentPatchNumber();
      print('🦋 [Shorebird] 當前 Patch 版本: ${currentPatch ?? "Base Release (無補丁)"}');

      final isAvailable = await _shorebirdCodePush.isNewPatchAvailableForDownload();
      if (isAvailable) {
        print('📥 [Shorebird] 發現新版 Patch！開始背景靜默下載...');
        await _shorebirdCodePush.downloadUpdateIfAvailable();
        print('✅ [Shorebird] Patch 下載完成！已準備就緒，等待安全時機重啟套用。');

        _isPatchReadyToInstall = true;
        _trySafeRestart();
      } else {
        print('🦋 [Shorebird] 目前已是最新的 Patch，無需更新。');
      }
    } catch (e) {
      print('❌ [Shorebird] 檢查更新失敗: $e');
    }
  }

  // 💡 [Shorebird] 安全重啟防護機制
  void _trySafeRestart() {
    if (!_isPatchReadyToInstall) return;

    // 🛡️ 防護 1：若目前處於緊急警報播放狀態，絕對不自動重啟
    if (_emergencyState.isAlarmActive) {
      print('⚠️ [Shorebird] 目前處於「緊急警報」狀態，暫緩自動重啟，等警報解除後重試。');
      return;
    }

    print('🔄 [Shorebird] 系統目前處於安全狀態，即將重啟套用最新熱補丁！');
    Restart.restartApp();
  }

  void _initGeofence() {
    _geofenceManager = GeofenceManager();

    // 💡 點一：當進入最高優先級區域
    _geofenceManager.onEnterHighestPriorityZone =
        (campaignId, playCmds, dlCmds) async {
          print('📍 [Geofence] 進入最高優先級活動區域: $campaignId');

          bool allFilesExist = true;

          // 檢查該活動播放清單中的影片是否都已存在本地
          for (final playCmd in playCmds) {
            final exists = await _downloadManager.isVideoExists(
              playCmd.videoFilename,
            );
            if (!exists) {
              allFilesExist = false;
              break; // 只要缺一通，就判定為檔案不齊全
            }
          }

          // 🌟 分流控制
          if (allFilesExist) {
            // 【如果有檔就播放】
            print('✅ [Geofence] 影片皆已就緒，立即切換播放 LBS 廣告清單');

            final playlist = playCmds
                .map(
                  (cmd) => PlaybackItem(
                    videoFilename: cmd.videoFilename,
                    advertisementId: cmd.advertisementId,
                    advertisementName: cmd.advertisementName,
                    trigger: cmd.trigger, // 'location_based'
                    campaignId: cmd.campaignId,
                  ),
                )
                .toList();

            await _playbackManager.startCampaignPlayback(
              campaignId: campaignId,
              playlist: playlist,
            );
          } else {
            // 【沒有檔就下載】目前的廣告不會被打斷，默默在背景吞下載指令
            print('📥 [Geofence] 發現缺失影片，維持現狀播放，背景啟動 LBS 下載指令');
            for (final dlCmd in dlCmds) {
              _shadowSync.handleLbsDownload(dlCmd); // 呼叫剛剛新增的方法
            }
          }
        };

    // 💡 點二：當離開所有區域
    _geofenceManager.onExitAllZones = () {
      print('👋 [Geofence] 離開所有 LBS 區域，恢復一般/本地預設播放清單');
      _playbackManager.revertToLocalPlayback();
    };
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

    _shadowSync.addDownloadCompletedListener(_handleDownloadCompleted);
    _playbackManager.addItemListener(_handlePlaybackItemChangedForSync);
    _playbackManager.addStateListener(_handlePlaybackStateChangedForSync);
  }

  Future<void> _handleDownloadCompleted() async {
    print('🔔 收到下載完成通知，更新播放清單與圍欄狀態');
    await _playbackManager.refreshLocalPlaylistAfterDownload();
    if (_latestPosition != null) {
      _geofenceManager.processLocationUpdate(_latestPosition!);
    }
  }

  void _handlePlaybackItemChangedForSync(PlaybackItem? currentItem) {
    print('📡 [狀態回報] 播放切換至: ${currentItem?.advertisementName}');
    if (_mqttManager.isConnected) {
      _shadowSync.publishReportedNow();
    }
  }

  void _handlePlaybackStateChangedForSync(PlaybackState state) {
    print('📡 [狀態回報] 播放器狀態變更為: $state');
    if (_mqttManager.isConnected) {
      _shadowSync.publishReportedNow();
    }
  }

  void _setupLocationCallbacks() {
    _locationService.onLocationUpdate = (position) {
      if (!mounted) return;

      // 1. 儲存最新座標
      _latestPosition = position;

      // 2. 💡 餵給管理器，它會自動幫你算距離、比對重疊、挑出最高優先級
      _geofenceManager.processLocationUpdate(position);

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

        _trySafeRestart();
      }
    }
  }

  Future<void> _handlePlayAdCommand(PlayAdCommand command) async {
    bool isReadyToPlay = await _downloadManager.isVideoExists(
      command.videoFilename,
    );

    // 1. 如果本地沒有檔案，觸發自動下載
    if (!isReadyToPlay) {
      print('📥 [自動下載] 本地無檔案，開始下載推播影片: ${command.videoFilename}');

      try {
        // 💡 使用 Completer 來等待非同步的下載完成
        final completer = Completer<bool>();

        // 改用你真實存在的 startDownload 方法
        final started = await _downloadManager.startDownload(
          advertisementId: command.advertisementId,
          onProgress: (task) {
            if (task.status == DownloadStatus.completed) {
              if (!completer.isCompleted) completer.complete(true);
            } else if (task.status == DownloadStatus.failed) {
              print('❌ [自動下載] 失敗原因: ${task.errorMessage}');
              if (!completer.isCompleted) completer.complete(false);
            }
          },
        );

        if (started) {
          // 在這裡卡住，直到 onProgress 告訴我們成功或失敗
          isReadyToPlay = await completer.future;

          // 💡 新增：下載成功後，要求系統重新掃描更新本地清單 UI
          if (isReadyToPlay) {
            print('🔄 [自動下載] 推播下載完畢，要求系統重新掃描更新本地清單 UI');
            await _playbackManager.refreshLocalPlaylist();
          }
        } else {
          print('❌ [自動下載] 無法啟動下載任務 (可能已在下載中，或無法獲取下載資訊)');
        }
      } catch (e) {
        print('❌ [自動下載] 發生錯誤，取消插播任務: $e');
      }
    }

    // 2. 如果檔案還是不存在（下載失敗），就直接 return 放棄插播
    if (!isReadyToPlay) {
      print('❌ [插播失敗] 影片未就緒，無法執行插播。');
      return;
    }

    // 3. 確定檔案存在（或剛下載完），執行強硬插播
    print('✅ [自動下載] 影片準備就緒，準備切換插播！');
    await _playbackManager.insertAd(
      videoFilename: command.videoFilename,
      advertisementId: command.advertisementId,
      advertisementName: command.advertisementName,
      isOverride: true, // 確保衝進隊列第一位並踢掉當前播放
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
    _shadowSync.removeDownloadCompletedListener(_handleDownloadCompleted);
    _playbackManager.removeItemListener(_handlePlaybackItemChangedForSync);
    _playbackManager.removeStateListener(_handlePlaybackStateChangedForSync);
    _mqttManager.dispose();
    _shorebirdTimer?.cancel();
    _downloadManager.dispose();
    _playbackManager.dispose();
    _locationService.dispose();
    super.dispose();
  }
}
