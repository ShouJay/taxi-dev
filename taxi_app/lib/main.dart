import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'config/app_config.dart';
import 'services/websocket_manager.dart';
import 'services/download_manager.dart';
import 'services/location_service.dart';
import 'managers/playback_manager.dart';
import 'screens/main_screen.dart';
import 'screens/settings_screen.dart';
import 'models/play_ad_command.dart';
import 'models/download_info.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 設置全螢幕模式
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // 允許直立與橫向，主畫面會依螢幕方向自動調整影片顯示
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const TaxiApp());
}

class TaxiApp extends StatelessWidget {
  const TaxiApp({Key? key}) : super(key: key);

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

/// App 容器 - 管理所有服務和狀態
class AppContainer extends StatefulWidget {
  const AppContainer({Key? key}) : super(key: key);

  @override
  State<AppContainer> createState() => _AppContainerState();
}

class _AppContainerState extends State<AppContainer>
    with WidgetsBindingObserver {
  late WebSocketManager _webSocketManager;
  late DownloadManager _downloadManager;
  late PlaybackManager _playbackManager;
  late LocationService _locationService;

  bool _showSettings = false;
  bool _isInitialized = false;
  bool _isAdminMode = false;
  Position? _latestPosition;
  DateTime? _lastLocationSentTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  /// 初始化應用
  Future<void> _initialize() async {
    try {
      print('🚀 初始化應用...');

      final prefs = await SharedPreferences.getInstance();

      // 1. 載入設備 ID
      final deviceId = await _loadDeviceId(prefs);
      print('📱 設備 ID: $deviceId');

      final adminMode = prefs.getBool(AppConfig.adminModeKey) ?? false;

      // 2. 初始化管理器
      _webSocketManager = WebSocketManager(
        deviceId: deviceId,
        serverUrl: AppConfig.wsUrl,
      );

      _downloadManager = DownloadManager(baseUrl: AppConfig.apiBaseUrl);

      _playbackManager = PlaybackManager(
        downloadManager: _downloadManager,
        webSocketManager: _webSocketManager,
      );

      // 初始化位置服務
      _locationService = LocationService(webSocketManager: _webSocketManager);
      _locationService.onLocationUpdate = (position) {
        if (!mounted) return;
        setState(() {
          _latestPosition = position;
          _lastLocationSentTime = _locationService.lastLocationSentTime;
        });
      };
      _locationService.onLocationAcknowledged = (_) {
        if (!mounted) return;
        setState(() {});
      };

      // 3. 設置 WebSocket 事件處理
      _setupWebSocketHandlers();

      // 4. 連接到伺服器
      _webSocketManager.connect();

      // 5. 啟動位置服務
      await _locationService.start();

      // 6. 開始自動播放（優先預設影片，其次本地影片）
      await _playbackManager.startAutoPlay();

      setState(() {
        _isInitialized = true;
        _isAdminMode = adminMode;
        _latestPosition = _locationService.currentPosition;
        _lastLocationSentTime = _locationService.lastLocationSentTime;
      });

      print('✅ 應用初始化完成');
    } catch (e) {
      print('❌ 初始化失敗: $e');
    }
  }

  /// 載入設備 ID
  Future<String> _loadDeviceId(SharedPreferences prefs) async {
    try {
      final deviceId = prefs.getString(AppConfig.deviceIdKey);

      if (deviceId != null && deviceId.isNotEmpty) {
        return deviceId;
      }

      // 使用預設設備 ID
      await prefs.setString(AppConfig.deviceIdKey, AppConfig.defaultDeviceId);
      return AppConfig.defaultDeviceId;
    } catch (e) {
      print('❌ 載入設備 ID 失敗: $e');
      return AppConfig.defaultDeviceId;
    }
  }

  Future<void> _updateAdminMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.adminModeKey, value);
    if (!mounted) return;
    setState(() {
      _isAdminMode = value;
    });
  }

  /// 設置 WebSocket 事件處理
  void _setupWebSocketHandlers() {
    // 處理播放廣告命令
    _webSocketManager.onPlayAdCommand = (command) {
      _handlePlayAdCommand(command);
    };

    // 處理下載影片命令
    _webSocketManager.onDownloadVideoCommand = (command) {
      _handleDownloadVideoCommand(command);
    };

    // 處理連接事件
    _webSocketManager.onConnected = () {
      print('✅ WebSocket 已連接');
      // 連線建立後立即補送一次最新位置
      _locationService.sendCurrentLocation();
    };

    _webSocketManager.onDisconnected = () {
      print('❌ WebSocket 已斷開');
    };

    _webSocketManager.onStartCampaignPlayback =
        (campaignId, playlistData) async {
          await _handleStartCampaignPlayback(campaignId, playlistData);
        };

    _webSocketManager.onRevertToLocalPlaylist = () async {
      print('🏠 收到 [REVERT_TO_LOCAL] 指令');
      await _playbackManager.revertToLocalPlayback();
    };
  }

  /// 處理播放廣告命令
  Future<void> _handlePlayAdCommand(PlayAdCommand command) async {
    print('🎬 處理播放廣告命令: ${command.advertisementName}');
    print('   來源：後端推送');
    print('   影片檔名: ${command.videoFilename}');

    // 檢查影片是否存在
    final exists = await _downloadManager.isVideoExists(command.videoFilename);

    if (!exists) {
      print('⚠️ 影片不存在: ${command.videoFilename}');
      print('   這是後端推送的播放命令，但本地沒有該影片');

      // 如果後端沒有提供 advertisement_id，無法請求下載
      if (command.advertisementId == 'unknown') {
        print('⚠️ 後端未提供 advertisement_id，無法請求下載');
        print('   提示：請確保後端在 play_ad 事件中包含 advertisement_id 字段');
        print('   後端應發送格式：');
        print('   {');
        print('     "command": "PLAY_VIDEO",');
        print('     "video_filename": "影片檔名",');
        print('     "advertisement_id": "adv-xxx",  ← 必須提供');
        print('     "advertisement_name": "廣告名稱",');
        print('     "trigger": "location_based",');
        print('     "timestamp": "2025-01-26T12:34:56"');
        print('   }');
        return;
      }

      print('📥 請求下載: ${command.advertisementId}');
      _webSocketManager.sendDownloadRequest(command.advertisementId);
      return;
    }

    // 影片存在，直接播放
    print('✅ 影片已存在，加入播放隊列');
    await _playbackManager.insertAd(
      videoFilename: command.videoFilename,
      advertisementId: command.advertisementId,
      advertisementName: command.advertisementName,
      isOverride: command.isOverride,
      trigger: command.trigger,
      campaignId: command.campaignId,
    );
  }

  /// 處理下載影片命令
  Future<void> _handleDownloadVideoCommand(DownloadVideoCommand command) async {
    print('📥 處理下載影片命令: ${command.advertisementName}');

    // 檢查影片是否已存在
    final exists = await _downloadManager.isVideoExists(command.videoFilename);
    if (exists) {
      print('✅ 影片已存在: ${command.videoFilename}');

      // 發送完成狀態
      _webSocketManager.sendDownloadStatus(
        advertisementId: command.advertisementId,
        status: 'completed',
        progress: 100,
        downloadedChunks: List.generate(command.totalChunks, (i) => i),
        totalChunks: command.totalChunks,
      );
      return;
    }

    // 檢查是否正在播放（播放中不能下載）
    if (_playbackManager.state == PlaybackState.playing ||
        _playbackManager.state == PlaybackState.loading) {
      print('⏸️ 正在播放中，暫緩下載: ${command.advertisementId}');
      // 暫緩下載，等待播放完成後再下載
      // 這裡可以選擇：1. 拒絕下載 2. 加入下載隊列等待播放完成
      // 目前選擇暫緩，提示用戶
      return;
    }

    // 開始下載
    final success = await _downloadManager.startDownload(
      advertisementId: command.advertisementId,
      onProgress: (task) async {
        // 發送下載進度
        _webSocketManager.sendDownloadStatus(
          advertisementId: task.advertisementId,
          status: task.status.value,
          progress: task.progress,
          downloadedChunks: task.downloadedChunks,
          totalChunks: task.totalChunks,
          errorMessage: task.errorMessage,
        );

        // 下載完成：僅更新本地循環列表，不插隊插播（新片納入本地輪播）
        if (task.status == DownloadStatus.completed) {
          print('✅ 下載完成: ${command.videoFilename}');
          await _playbackManager.refreshLocalPlaylistAfterDownload();
        }
      },
    );

    if (!success) {
      print('❌ 啟動下載失敗: ${command.advertisementId}');
    }
  }

  /// 處理活動播放命令
  Future<void> _handleStartCampaignPlayback(
    String campaignId,
    List<dynamic> playlistData,
  ) async {
    print('🎬 收到 [START_CAMPAIGN_PLAYBACK] 指令，活動: $campaignId');

    final playlist = playlistData
        .map((item) => _parseCampaignPlaylistItem(campaignId, item))
        .whereType<PlaybackItem>()
        .toList();

    await _validateAndStartCampaign(campaignId, playlist);
  }

  /// 將原始資料解析為 PlaybackItem
  PlaybackItem? _parseCampaignPlaylistItem(String campaignId, dynamic rawItem) {
    if (rawItem is! Map<String, dynamic>) {
      print('⚠️ 無法解析活動播放項目: $rawItem');
      return null;
    }

    final videoFilename =
        rawItem['videoFilename'] as String? ??
        rawItem['video_filename'] as String? ??
        '';

    if (videoFilename.isEmpty) {
      print('⚠️ 活動播放項目缺少 videoFilename: $rawItem');
      return null;
    }

    final advertisementId =
        rawItem['advertisementId'] as String? ??
        rawItem['advertisement_id'] as String? ??
        'campaign-$campaignId-$videoFilename';

    final advertisementName =
        rawItem['advertisementName'] as String? ??
        rawItem['advertisement_name'] as String? ??
        videoFilename;

    final trigger = rawItem['trigger'] as String? ?? 'campaign';

    return PlaybackItem(
      videoFilename: videoFilename,
      advertisementId: advertisementId,
      advertisementName: advertisementName,
      trigger: trigger,
      campaignId: campaignId,
    );
  }

  /// 驗證活動播放列表並啟動播放
  Future<void> _validateAndStartCampaign(
    String campaignId,
    List<PlaybackItem> playlist,
  ) async {
    if (playlist.isEmpty) {
      print('⚠️ 活動 $campaignId 播放列表為空，不切換');
      return;
    }

    for (var i = 0; i < playlist.length; i++) {
      final item = playlist[i];
      final exists = await _downloadManager.isVideoExists(item.videoFilename);
      if (!exists) {
        print('❌ 嚴重錯誤：影片 ${item.videoFilename} 未預先載入！');

        _webSocketManager.sendPlaybackError(
          error: '影片未預先載入',
          campaignId: campaignId,
          videoFilename: item.videoFilename,
          advertisementId: item.advertisementId,
          mode: 'campaign',
          playlistIndex: i,
          playlistLength: playlist.length,
          trigger: item.trigger,
        );
        return;
      }
    }

    print('✅ 驗證通過，所有影片均已預載。');
    await _playbackManager.startCampaignPlayback(
      campaignId: campaignId,
      playlist: playlist,
    );
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
            webSocketManager: _webSocketManager,
            playbackManager: _playbackManager,
            downloadManager: _downloadManager,
            locationService: _locationService,
            isAdminMode: _isAdminMode,
            onAdminModeChanged: _updateAdminMode,
            onBack: () {
              setState(() {
                _showSettings = false;
              });
            },
          )
        : MainScreen(
            playbackManager: _playbackManager,
            downloadManager: _downloadManager,
            isAdminMode: _isAdminMode,
            latestPosition: _latestPosition,
            lastLocationSentTime: _lastLocationSentTime,
            onSettingsRequested: () {
              setState(() {
                _showSettings = true;
              });
            },
          );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 處理應用生命週期變化
    if (state == AppLifecycleState.paused) {
      print('⏸️ 應用進入背景');
      // 可以在這裡暫停某些操作
    } else if (state == AppLifecycleState.resumed) {
      print('▶️ 應用恢復前景');
      // 重新連接 WebSocket（如果斷開）
      if (!_webSocketManager.isConnected) {
        _webSocketManager.connect();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _webSocketManager.dispose();
    _downloadManager.dispose();
    _playbackManager.dispose();
    _locationService.dispose();
    super.dispose();
  }
}
