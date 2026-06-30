import 'dart:async';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../config/app_config.dart';
import '../services/download_manager.dart';

/// 播放項目
class PlaybackItem {
  final String videoFilename;
  final String advertisementId;
  final String advertisementName;
  final String trigger;
  final String? campaignId;
  final bool isOverride;
  final DateTime addedAt;

  PlaybackItem({
    required this.videoFilename,
    required this.advertisementId,
    required this.advertisementName,
    required this.trigger,
    this.campaignId,
    this.isOverride = false,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();
}

/// 播放狀態
enum PlaybackState { idle, loading, playing, paused, error }

/// 播放模式
enum PlaybackMode { local, campaign }

/// 播放資訊（用於顯示播放列表）
class PlaybackInfo {
  final String filename;
  final String title;
  final bool isCurrentPlaying;
  final bool isLocalVideo;
  final String? advertisementId;

  PlaybackInfo({
    required this.filename,
    required this.title,
    required this.isCurrentPlaying,
    required this.isLocalVideo,
    this.advertisementId,
  });
}

/// 播放管理器
class PlaybackManager {
  final DownloadManager downloadManager;

  // 當前播放控制器
  VideoPlayerController? _currentController;

  // 播放狀態
  PlaybackState _state = PlaybackState.idle;
  PlaybackMode _playbackMode = PlaybackMode.local;

  // 播放隊列（用於插入廣告、覆蓋播放等）
  final List<PlaybackItem> _queue = [];

  // 當前播放項目
  PlaybackItem? _currentItem;

  // 💡 【雙引擎新增】背景預載專用控制器與項目
  VideoPlayerController? _preloadController;
  PlaybackItem? _preloadItem;

  // 本地播放列表（循環播放用）
  List<PlaybackItem> _localPlaylist = [];
  int _localPlaylistIndex = 0;

  // 活動播放列表
  List<PlaybackItem>? _campaignPlaylist;
  int _campaignPlaylistIndex = 0;
  String? _activeCampaignId;

  // 位置觸發的廣告（追蹤最後一次位置觸發的廣告，用於過期清理）
  final Map<String, DateTime> _locationBasedAds = {};

  // 播放啟用狀態（出廠／無本地影片時由 _syncPlaybackEnabledWithPrefsAndPlaylist 設為 false）
  bool _isPlaybackEnabled = false;

  /// 使用者或管理員主動暫停（與播放到片尾區分，避免片尾暫停被誤判為「播完」）
  bool _userPausedPlayback = false;

  /// 錯誤後只排程一次恢復播放
  bool _playbackErrorRecoveryScheduled = false;

  /// 活動模式連續缺檔次數（避免同一缺檔無限重試）
  int _campaignMissingFileStreak = 0;

  // 狀態監聽器
  Function(PlaybackState)? onStateChanged;
  Function(PlaybackItem?)? onItemChanged;
  Function(bool)? onPlaybackEnabledChanged;

  // 內部狀態
  bool _isDisposed = false;
  bool _playbackCompletedHandled = false; // 防止重複處理播放完成
  // 💡 新增：播放器核心初始化防護鎖，防止非同步插隊攪局
  bool _isInitializingNewVideo = false;

  // 💡 【雙引擎新增】防止瞬間重複切換的鎖
  bool _isSwapping = false;

  // 播放配置
  static const Duration _errorRetryDelay = Duration(seconds: 2);
  static const Duration _playbackEndTolerance = Duration(milliseconds: 400);

  PlaybackManager({
    required this.downloadManager,
  });

  // Getters
  VideoPlayerController? get controller => _currentController;
  PlaybackState get state => _state;
  PlaybackMode get playbackMode => _playbackMode;
  PlaybackItem? get currentItem => _currentItem;
  int get queueLength => _queue.length;
  bool get isPlaybackEnabled => _isPlaybackEnabled;
  String? get activeCampaignId => _activeCampaignId;

  /// 初始化並開始自動播放（依 SharedPreferences 與本地是否有影片決定是否啟用播放）
  Future<void> startAutoPlay() async {
    if (_isDisposed) return;

    print('🎬 開始自動播放...');

    // 設置為本地循環播放模式
    _playbackMode = PlaybackMode.local;
    _localPlaylistIndex = 0;

    await refreshLocalPlaylist();
    await _syncPlaybackEnabledWithPrefsAndPlaylist();

    if (_localPlaylist.isNotEmpty) {
      print('✅ 找到 ${_localPlaylist.length} 個本地影片');
      if (_isPlaybackEnabled) {
        await _playNext();
      } else {
        print('⚠️ 播放未啟用（無本地影片出廠預設，或使用者已關閉）');
        _setState(PlaybackState.idle);
      }
    } else {
      print('⚠️ 沒有找到本地影片');
      _setState(PlaybackState.idle);
    }
  }

  /// 依偏好與本地列表同步「是否啟用播放」：
  /// - 本地無任何影片 → 一律不啟用
  /// - 尚未寫入過 playback_enabled → 有影片則啟用、無影片則不啟用（出廠）
  /// - 已寫入過 → 依使用者儲存的值
  Future<void> _syncPlaybackEnabledWithPrefsAndPlaylist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_localPlaylist.isEmpty) {
      _isPlaybackEnabled = false;
    } else if (prefs.containsKey(AppConfig.playbackEnabledKey)) {
      _isPlaybackEnabled = prefs.getBool(AppConfig.playbackEnabledKey) ?? false;
    } else {
      _isPlaybackEnabled = true;
    }
    onPlaybackEnabledChanged?.call(_isPlaybackEnabled);
  }

  /// 下載完成後僅更新本地循環列表，不插隊插播；必要時在閒置狀態下開始循環
  Future<void> refreshLocalPlaylistAfterDownload() async {
    if (_isDisposed) return;
    await refreshLocalPlaylist();
    await _syncPlaybackEnabledWithPrefsAndPlaylist();
    if (!_isPlaybackEnabled) return;
    if (_state != PlaybackState.idle && _state != PlaybackState.error) return;
    if (_queue.isNotEmpty) return;
    if (_localPlaylist.isEmpty) return;
    await _playNext();
  }

  /// 刷新本地播放列表
  /// 💡 加上一個參數：[isTriggeredByCompleted] 是否為播放完畢自動切歌觸發
  Future<void> refreshLocalPlaylist({bool isTriggeredByCompleted = false}) async {
    try {
      final videoFilenames = await downloadManager.getAllDownloadedVideos();

      // 💡 只有在「不是播完切歌」的情況下，才啟用防重複攔截
      if (!isTriggeredByCompleted && _localPlaylist.length == videoFilenames.length) {
        bool isIdentical = true;
        for (int i = 0; i < videoFilenames.length; i++) {
          if (_localPlaylist[i].videoFilename != videoFilenames[i]) {
            isIdentical = false;
            break;
          }
        }
        if (isIdentical) {
          return; // 外部 GPS 觸發且檔案沒變，優雅退出
        }
      }

      // 如果是播完切歌，或者是硬碟檔案真的有變，重新建立清單
      _localPlaylist = videoFilenames
          .map(
            (filename) => PlaybackItem(
          videoFilename: filename,
          advertisementId: 'local-$filename',
          advertisementName: filename,
          trigger: 'local_loop',
        ),
      )
          .toList();

      print('📋 本地播放列表已整理: ${_localPlaylist.length} 個影片 (播完切歌=$isTriggeredByCompleted)');
    } catch (e) {
      print('❌ 刷新本地播放列表失敗: $e');
      _localPlaylist = [];
    }
  }

  /// 插入廣告到播放隊列
  Future<void> insertAd({
    required String videoFilename,
    required String advertisementId,
    required String advertisementName,
    required String trigger,
    String? campaignId,
    bool isOverride = false,
  }) async {
    if (_isDisposed) return;

    final item = PlaybackItem(
      videoFilename: videoFilename,
      advertisementId: advertisementId,
      advertisementName: advertisementName,
      trigger: trigger,
      campaignId: campaignId,
      isOverride: isOverride,
    );

    // 覆蓋播放：立即清除隊列並播放（若正在載入，佇列保留，於 initialize 完成後改播覆蓋）
    if (isOverride) {
      print('🚨 覆蓋播放: $advertisementName');
      _queue.clear();
      _queue.add(item);
      if (_state == PlaybackState.loading) {
        return;
      }
      await _playNext();
      return;
    }

    // 位置觸發的廣告：記錄時間戳
    if (trigger == 'location_based') {
      _locationBasedAds[advertisementId] = DateTime.now();
    }

    // 一般插入到隊列
    _queue.add(item);
    print('📥 廣告已加入隊列: $advertisementName (隊列長度: ${_queue.length})');

    // 如果當前沒有在播放，立即播放（但不要在 loading 時打斷）
    if (_state == PlaybackState.idle || _state == PlaybackState.error) {
      await _playNext();
    }
    // loading 狀態時，不執行播放，等待當前載入完成
  }

  /// 開始活動播放
  Future<void> startCampaignPlayback({
    required String campaignId,
    required List<PlaybackItem> playlist,
  }) async {
    if (_isDisposed || playlist.isEmpty) return;

    print('🎬 開始活動播放: $campaignId (${playlist.length} 個影片)');

    _campaignPlaylist = playlist;
    _campaignPlaylistIndex = 0;
    _campaignMissingFileStreak = 0;
    _activeCampaignId = campaignId;
    _playbackMode = PlaybackMode.campaign;

    // 清空一般隊列，活動播放優先
    _queue.clear();

    // 開始播放活動列表的第一個影片
    await _playCampaignItem();
  }

  /// 恢復到本地播放
  Future<void> revertToLocalPlayback() async {
    if (_isDisposed) return;

    // 💡 調整：只有當「真正處於播放中」且「不是正在切歌/播完的空檔」才攔截
    if (_playbackMode == PlaybackMode.local &&
        _state == PlaybackState.playing &&
        _currentController != null &&
        _currentController!.value.isPlaying) {
      return;
    }

    print('🏠 恢復到本地播放');
    _campaignPlaylist = null;
    _campaignPlaylistIndex = 0;
    _activeCampaignId = null;
    _playbackMode = PlaybackMode.local;

    // 💡 注意：這裡要傳入 false，告訴它「這不是因為播完要切歌，這是外部初始化」
    await refreshLocalPlaylist(isTriggeredByCompleted: false);
    await _syncPlaybackEnabledWithPrefsAndPlaylist();

    if (_isPlaybackEnabled) {
      if (_state == PlaybackState.idle || _state == PlaybackState.error || _currentController == null) {
        await _playNext();
      }
    } else {
      await _stopCurrentVideo();
      _setState(PlaybackState.idle);
    }
  }

  /// 檢查並清理過期的位置廣告
  void checkAndClearExpiredLocationAds({required Duration timeout}) {
    final now = DateTime.now();
    final expiredAds = <String>[];

    _locationBasedAds.forEach((adId, timestamp) {
      if (now.difference(timestamp) > timeout) {
        expiredAds.add(adId);
      }
    });

    if (expiredAds.isNotEmpty) {
      print('🗑️ 清理過期位置廣告: ${expiredAds.length} 個');
      for (final adId in expiredAds) {
        _locationBasedAds.remove(adId);
        // 從隊列中移除過期的位置廣告
        _queue.removeWhere(
          (item) =>
              item.advertisementId == adId && item.trigger == 'location_based',
        );
      }
    }
  }

  /// 設置播放啟用狀態（寫入 SharedPreferences，供出廠／重啟後還原）
  Future<void> setPlaybackEnabled(bool enabled) async {
    if (_isDisposed) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConfig.playbackEnabledKey, enabled);

    _isPlaybackEnabled = enabled;
    onPlaybackEnabledChanged?.call(enabled);

    // 如果正在 loading，偏好已寫入，待載入完成後於 _playItem 依 enabled 決定 play 或 paused
    if (_state == PlaybackState.loading) {
      print('⏳ 正在載入中，載入完成後套用播放開關');
      return;
    }

    if (!enabled) {
      await pause();
    } else {
      if (_state == PlaybackState.paused) {
        await resume();
      } else if (_state == PlaybackState.idle || _state == PlaybackState.error) {
        await _playNext();
      }
    }
  }

  /// 暫停播放
  Future<void> pause() async {
    if (_isDisposed || _currentController == null) return;

    // 如果正在 loading，不要暫停，等待載入完成
    if (_state == PlaybackState.loading) {
      print('⏳ 正在載入中，無法暫停');
      return;
    }

    if (_state == PlaybackState.playing) {
      _userPausedPlayback = true;
      await _currentController!.pause();
      _setState(PlaybackState.paused);
    }
  }

  /// 恢復播放
  Future<void> resume() async {
    if (_isDisposed || _currentController == null) return;

    // 如果正在 loading，不要恢復，等待載入完成
    if (_state == PlaybackState.loading) {
      print('⏳ 正在載入中，無法恢復播放');
      return;
    }

    if (_state == PlaybackState.paused && _isPlaybackEnabled) {
      _userPausedPlayback = false;
      await _currentController!.play();
      _setState(PlaybackState.playing);
    }
  }

  /// 播放活動列表中的項目
  Future<void> _playCampaignItem() async {
    if (_isDisposed || _campaignPlaylist == null) {
      return;
    }

    // 如果索引超出範圍，循環播放（重置索引）
    if (_campaignPlaylistIndex >= _campaignPlaylist!.length) {
      _campaignPlaylistIndex = 0;
      print('🔄 活動播放列表循環，回到第一個影片');
    }

    final item = _campaignPlaylist![_campaignPlaylistIndex];
    await _playItem(item);
  }

  /// 💡 【雙引擎核心】在背景預先載入下一支影片
  Future<void> _preloadNextVideo() async {
    if (_isDisposed || !_isPlaybackEnabled) return;

    PlaybackItem? nextItem;

    // 1. 決定下一支要播什麼（與 _playNext 邏輯類似，但不改變全域 index）
    if (_queue.isNotEmpty) {
      nextItem = _queue.first; // 預載隊列中的第一個
    } else if (_playbackMode == PlaybackMode.campaign && _campaignPlaylist != null) {
      int nextIndex = (_campaignPlaylistIndex + 1) % _campaignPlaylist!.length;
      nextItem = _campaignPlaylist![nextIndex];
    } else if (_localPlaylist.isNotEmpty) {
      // 💡 預判下一個本地循環索引（不修改目前的 _localPlaylistIndex）
      int nextIndex = (_localPlaylistIndex) % _localPlaylist.length;
      nextItem = _localPlaylist[nextIndex];
    }

    if (nextItem == null) return;

    print('📦 [雙引擎預載] 開始在背景初始化下一支影片: ${nextItem.advertisementName}');

    try {
      final videoPath = await downloadManager.getVideoPath(nextItem.videoFilename);
      final file = File(videoPath);

      if (!await file.exists()) {
        print('⚠️ [雙引擎預載] 檔案不存在，放棄預載');
        return;
      }

      // 建立預載控制器並初始化
      final controller = VideoPlayerController.file(file);
      await controller.initialize().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('背景預載超時'),
      );

      // 初始化成功，存入預載變數待命
      _preloadController = controller;
      _preloadItem = nextItem;
      print('✅ [雙引擎預載] 下一支影片已就緒，等待前台播完瞬間切換！');

    } catch (e) {
      print('❌ [雙引擎預載] 背景預載失敗 (將在換歌時降級為即時載入): $e');
      _preloadController?.dispose();
      _preloadController = null;
      _preloadItem = null;
    }
  }

  /// 播放下一個項目
  Future<void> _playNext() async {
    if (_isDisposed || !_isPlaybackEnabled) return;

    // 💡 如果防護罩開著，而且目前前台確實有控制器在運作中，才需要攔截
    if (_isInitializingNewVideo && _currentController != null) {
      print('⏳ 核心正在初始化新影片中，不重複執行 _playNext');
      return;
    }

    // 優先播放隊列中的項目
    if (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      await _playItem(item);
      return;
    }

    // 活動播放模式：播放活動列表
    if (_playbackMode == PlaybackMode.campaign && _campaignPlaylist != null) {
      await _playCampaignItem();
      return;
    }

    // 本地播放模式：循環播放本地列表
    if (_localPlaylist.isNotEmpty) {
      // 確保索引在有效範圍內（防止越界）
      if (_localPlaylistIndex >= _localPlaylist.length || _localPlaylistIndex < 0) {
        _localPlaylistIndex = 0;
      }

      final item = _localPlaylist[_localPlaylistIndex];
      final currentIndex = _localPlaylistIndex;

      // 💡 核心：使用模運算，計算真正的下一個播放索引，確保無限 1 -> 2 -> 3 -> 1 循環
      _localPlaylistIndex = (_localPlaylistIndex + 1) % _localPlaylist.length;

      print(
        '📺 播放本地影片 [${currentIndex + 1}/${_localPlaylist.length}]: ${item.advertisementName}',
      );
      print('   模式: $_playbackMode, 下一個索引: $_localPlaylistIndex');

      await _playItem(item);
      return;
    }

    print('⚠️ 本地播放列表為空，無法播放');
    _setState(PlaybackState.idle);
  }

  /// 播放指定項目
  Future<void> _playItem(PlaybackItem item) async {
    if (_isDisposed) return;

    if (_isInitializingNewVideo) {
      print('⏳ [晶片隔離] 已經有影片正在初始化中，跳過重複請求。');
      return;
    }

    _isInitializingNewVideo = true;
    print('🎬 [晶片隔離] 開始準備加載新影片: ${item.advertisementName}');

    // 1. 舊播放器徹底背景化、自由化釋放
    if (_currentController != null) {
      final oldController = _currentController!;
      _currentController = null;

      try {
        oldController.removeListener(_onVideoControllerUpdate);
        oldController.pause().then((_) => oldController.dispose()).catchError((e) {
          print('⚠️ 背景釋放舊播放器異常 (忽略即可): $e');
        });
        print('🧹 [晶片隔離] 舊播放器已丟至背景安全排隊銷毀...');
      } catch (e) {
        print('⚠️ 移出舊播放器基本操作異常: $e');
      }
    }

    // 給 Android 緩衝池物理空檔
    await Future.delayed(const Duration(milliseconds: 150));

    _setCurrentItem(item);
    _setState(PlaybackState.loading);

    final videoPath = await downloadManager.getVideoPath(item.videoFilename);
    final file = File(videoPath);

    if (!await file.exists()) {
      print('❌ 影片檔案不存在: $videoPath');
      _setState(PlaybackState.error);
      _isInitializingNewVideo = false;
      _playNext();
      return;
    }

    final controller = VideoPlayerController.file(file);
    _currentController = controller;

    try {
      controller.addListener(_onVideoControllerUpdate);
      print('⏳ [晶片隔離] 啟動全新 MediaCodec 晶片初始化...');

      // ========================================================
      // 💡 【超強心臟修正點】加上 3 秒超時防線
      // 如果因為 MQTT 插隊導致 ExoPlayer 的 Initialized 事件被作業系統吞掉，
      // 3 秒一到立刻切斷，絕對不讓它死鎖在這邊！
      // ========================================================
      await controller.initialize().timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw TimeoutException('高通 MediaCodec 晶片事件插隊或初始化超時');
        },
      );

      if (_isDisposed || _currentController != controller) {
        controller.dispose();
        _isInitializingNewVideo = false;
        return;
      }

      await controller.play();
      _setState(PlaybackState.playing);

      _preloadNextVideo();
      print('🚀 [晶片隔離] 影片成功渲染並順利播放！');

      _isInitializingNewVideo = false; // 順利開播，安全解鎖

    } catch (e) {
      print('❌ [終極備援] 初始化新播放器失敗或遭事件吞噬: $e');
      _setState(PlaybackState.error);

      // 徹底剝離報錯的控制器
      controller.removeListener(_onVideoControllerUpdate);
      try {
        controller.dispose();
      } catch (_) {}
      if (_currentController == controller) {
        _currentController = null;
      }

      // 💡 關鍵解鎖：即使被吞噬，防護罩也一定要關掉，並立刻驅動下一首！
      _isInitializingNewVideo = false;

      print('🔄 [終極備援] 觸發自癒程序，跳過本首，直接驅動下一首影片...');
      // 延遲 200ms 後強制切歌，給系統喘息空檔
      Future.delayed(const Duration(milliseconds: 200), () {
        _playNext();
      });
    }
  }

  void _schedulePlaybackErrorRecovery() {
    if (_playbackErrorRecoveryScheduled || _isDisposed) return;
    _playbackErrorRecoveryScheduled = true;
    Future.delayed(_errorRetryDelay, () {
      _playbackErrorRecoveryScheduled = false;
      if (!_isDisposed) {
        _playNext();
      }
    });
  }

  /// 視頻控制器更新監聽
  void _onVideoControllerUpdate() {
    if (_isDisposed || _currentController == null) return;

    final controller = _currentController!;
    final value = controller.value;

    if (value.hasError) {
      // ... 原本的錯誤處理維持不變 ...
      return;
    }

    if (_isSwapping) return; // 正在無縫切換中，防止重複觸發

    // 緩衝期防線
    if (!value.isInitialized || value.position.inMilliseconds < 200) return;

    // 💡 自然播完判定
    if (!value.isLooping && !value.isPlaying && !_userPausedPlayback) {
      final atEnd = value.duration >= _playbackEndTolerance
          ? value.position >= value.duration - _playbackEndTolerance
          : value.position >= value.duration;

      if (atEnd) {
        _isSwapping = true; // 上鎖，開始無縫切換
        print('🎉 [雙引擎] 影片播完，執行瞬間切換！');

        controller.removeListener(_onVideoControllerUpdate);

        // 💡 核心切換邏輯：如果有預載好的，瞬間上膛！
        if (_preloadController != null && _preloadController!.value.isInitialized) {

          // 1. 把舊的丟到背景釋放
          final oldController = _currentController;
          oldController?.pause().then((_) => oldController.dispose());

          // 2. 指標瞬間切換為預載控制器
          _currentController = _preloadController;
          _setCurrentItem(_preloadItem);

          // 3. 綁定監聽器並立刻播放
          _currentController!.addListener(_onVideoControllerUpdate);
          _currentController!.play();

          // 4. 更新狀態，通知 UI 刷新播放器
          _setState(PlaybackState.playing);

          // 5. 推進索引（因為預載的影片已經正式上線了）
          if (_playbackMode == PlaybackMode.local && _localPlaylist.isNotEmpty) {
            _localPlaylistIndex = (_localPlaylistIndex + 1) % _localPlaylist.length;
          } else if (_playbackMode == PlaybackMode.campaign && _campaignPlaylist != null) {
            _campaignPlaylistIndex = (_campaignPlaylistIndex + 1) % _campaignPlaylist!.length;
          }

          // 6. 清空預載變數，並立刻在背景準備「下一支」
          _preloadController = null;
          _preloadItem = null;
          _isSwapping = false;

          print('🚀 [雙引擎] 無縫切換成功！啟動下一輪預載...');
          _preloadNextVideo(); // 啟動背景預載下一支

        } else {
          // 💡 備援機制：如果預載失敗或來不及，走原來的流程驅動下一首
          print('⚠️ [雙引擎] 預載未就緒，降級為傳統切歌模式');
          _isSwapping = false;
          _playNext();
        }
      }
    }
  }

  /// 停止當前播放
  Future<void> _stopCurrentVideo() async {
    if (_currentController == null) return;

    try {
      // 移除監聽器
      _currentController!.removeListener(_onVideoControllerUpdate);
      await _currentController!.pause();
      await _currentController!.dispose();
    } catch (e) {
      print('⚠️ 停止播放時發生錯誤: $e');
    } finally {
      _currentController = null;
      _playbackCompletedHandled = false;
      _userPausedPlayback = false;
    }
  }

  /// 設置播放狀態
  void _setState(PlaybackState newState) {
    if (_state != newState) {
      _state = newState;
      onStateChanged?.call(_state);
    }
  }

  /// 設置當前播放項目
  void _setCurrentItem(PlaybackItem? item) {
    if (_currentItem?.advertisementId != item?.advertisementId) {
      _currentItem = item;
      onItemChanged?.call(_currentItem);
    }
  }

  /// 獲取完整播放列表（用於顯示）
  List<PlaybackInfo> getFullPlaylist() {
    final List<PlaybackInfo> playlist = [];

    // 添加隊列中的項目
    for (var item in _queue) {
      playlist.add(
        PlaybackInfo(
          filename: item.videoFilename,
          title: item.advertisementName,
          isCurrentPlaying: false,
          isLocalVideo: false,
          advertisementId: item.advertisementId,
        ),
      );
    }

    // 添加活動播放列表
    if (_campaignPlaylist != null) {
      for (var i = 0; i < _campaignPlaylist!.length; i++) {
        final item = _campaignPlaylist![i];
        final isCurrent =
            i == _campaignPlaylistIndex &&
            _currentItem?.advertisementId == item.advertisementId;
        playlist.add(
          PlaybackInfo(
            filename: item.videoFilename,
            title: item.advertisementName,
            isCurrentPlaying: isCurrent,
            isLocalVideo: false,
            advertisementId: item.advertisementId,
          ),
        );
      }
    }

    // 添加本地播放列表
    for (var i = 0; i < _localPlaylist.length; i++) {
      final item = _localPlaylist[i];
      final isCurrent =
          _playbackMode == PlaybackMode.local &&
          i == (_localPlaylistIndex - 1) % _localPlaylist.length &&
          _currentItem?.advertisementId == item.advertisementId;
      playlist.add(
        PlaybackInfo(
          filename: item.videoFilename,
          title: item.advertisementName,
          isCurrentPlaying: isCurrent,
          isLocalVideo: true,
          advertisementId: item.advertisementId,
        ),
      );
    }

    return playlist;
  }

  /// 刪除影片
  Future<bool> deleteVideo(String filename) async {
    try {
      // 獲取影片路徑
      final videoPath = await downloadManager.getVideoPath(filename);
      final file = File(videoPath);

      // 檢查檔案是否存在
      if (!await file.exists()) {
        print('⚠️ 影片不存在: $filename');
        return false;
      }

      // 如果正在播放這個影片，先停止
      if (_currentItem?.videoFilename == filename) {
        await _stopCurrentVideo();
        _setCurrentItem(null);
        _setState(PlaybackState.idle);
      }

      // 刪除檔案並與磁碟同步播放列表／播放開關
      await file.delete();
      print('✅ 影片已刪除: $filename');

      await refreshLocalPlaylist();
      await _syncPlaybackEnabledWithPrefsAndPlaylist();

      if (_state == PlaybackState.idle &&
          _localPlaylist.isNotEmpty &&
          _isPlaybackEnabled) {
        await _playNext();
      }

      return true;
    } catch (e) {
      print('❌ 刪除影片失敗: $e');
      return false;
    }
  }

  /// 清理資源
  void dispose() {
    if (_isDisposed) return;

    print('🗑️ 清理播放管理器...');
    _isDisposed = true;

    // 停止並釋放控制器
    _stopCurrentVideo();

    // 清空列表
    _queue.clear();
    _localPlaylist.clear();
    _campaignPlaylist = null;
    _locationBasedAds.clear();

    print('✅ 播放管理器已清理');
  }
}
