import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../managers/playback_manager.dart';
import '../models/play_ad_command.dart';
import '../models/shadow_playlist.dart';
import '../models/download_info.dart';
import 'download_manager.dart';
import 'mqtt_manager.dart';

/// Device Shadow 同步服務
/// 負責 desired/reported 對齊、MD5 自檢、背景下載、LRU 垃圾回收
class ShadowSyncService {
  final MqttManager mqttManager;
  final DownloadManager downloadManager;

  DesiredPlaylist? _currentDesired;
  String? _activeCampaignId;
  final Map<String, int> _downloadProgress = {};
  final List<ReportedError> _errors = [];
  final Map<String, String> _videoIdToFilename = {};
  bool _isSyncing = false;

  // 回調
  Function(String campaignId, List<PlaybackItem> playlist)? onCampaignReady;
  Function()? onRevertToLocal;
  Function(PlayAdCommand)? onOverridePlay;

  ShadowSyncService({
    required this.mqttManager,
    required this.downloadManager,
  });

  DesiredPlaylist? get currentDesired => _currentDesired;

  /// 處理後端下發的 desired 播放清單
  Future<void> handleDesired(DesiredPlaylist desired) async {
    // 管理員指令優先處理
    final cmdType = desired.commandType;
    if (cmdType == 'REVERT_TO_LOCAL_PLAYLIST') {
      print('🏠 收到 REVERT_TO_LOCAL 指令');
      _activeCampaignId = null;
      onRevertToLocal?.call();
      await _publishReported();
      return;
    }

    if (cmdType == 'PLAY_VIDEO') {
      await _handleOverridePlay(desired);
      return;
    }

    // 若 desired 未變更，略過
    if (_currentDesired?.updatedAt != null &&
        _currentDesired!.updatedAt == desired.updatedAt &&
        _currentDesired!.campaignId == desired.campaignId) {
      return;
    }

    print('📋 對齊 desired: campaign=${desired.campaignId}, videos=${desired.videos.length}');
    _currentDesired = desired;
    _errors.clear();

    await _garbageCollect(desired);
    await _syncDownloads(desired);

    if (desired.videos.isEmpty) {
      print('📭 desired 播放清單為空，維持本地播放');
      _activeCampaignId = null;
      onRevertToLocal?.call();
    } else if (_allVideosReady(desired)) {
      await _switchToCampaign(desired);
    }

    await _publishReported();
  }

  Future<void> _handleOverridePlay(DesiredPlaylist desired) async {
    final cmd = desired.command;
    if (cmd == null) return;

    final videoFilename = cmd['video_filename'] as String? ?? '';
    final advertisementId = cmd['advertisement_id'] as String? ?? '';
    if (videoFilename.isEmpty) return;

    final exists = await downloadManager.isVideoExists(videoFilename);
    if (!exists && advertisementId.isNotEmpty) {
      await _downloadVideo(
        DesiredVideo(
          videoId: advertisementId,
          url: '',
          videoFilename: videoFilename,
        ),
      );
    }

    if (await downloadManager.isVideoExists(videoFilename)) {
      onOverridePlay?.call(
        PlayAdCommand(
          command: 'PLAY_VIDEO',
          videoFilename: videoFilename,
          advertisementId: advertisementId,
          advertisementName: cmd['advertisement_name'] as String? ?? videoFilename,
          trigger: cmd['trigger'] as String? ?? 'admin_override',
          priority: 'override',
          timestamp: DateTime.now(),
        ),
      );
    }
    await _publishReported();
  }

  Future<void> _syncDownloads(DesiredPlaylist desired) async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      for (final video in desired.videos) {
        final filename = await _resolveFilename(video);
        if (filename == null) continue;

        _videoIdToFilename[video.videoId] = filename;

        if (await downloadManager.isVideoExists(filename)) {
          if (video.md5 != null && video.md5!.isNotEmpty) {
            final md5Ok = await downloadManager.verifyFileMd5(
              filename,
              expectedMd5: video.md5!,
            );
            if (!md5Ok) {
              await downloadManager.deleteVideoFile(filename);
              _errors.add(
                ReportedError(
                  videoId: video.videoId,
                  code: 'MD5_MISMATCH',
                  message: 'File corrupted, retrying...',
                ),
              );
            } else {
              _downloadProgress[video.videoId] = 100;
              continue;
            }
          } else {
            _downloadProgress[video.videoId] = 100;
            continue;
          }
        }

        _downloadProgress[video.videoId] = 0;
        await _downloadVideo(video);
        await _publishReported();

        if (_allVideosReady(desired)) {
          await _switchToCampaign(desired);
          await _publishReported();
          break;
        }
      }
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _downloadVideo(DesiredVideo video) async {
    final success = await downloadManager.startDownload(
      advertisementId: video.videoId,
      expectedMd5: video.md5,
      onProgress: (task) {
        _downloadProgress[video.videoId] = task.progress;
        if (task.status == DownloadStatus.completed && task.outputFile != null) {
          _videoIdToFilename[video.videoId] = task.downloadInfo.filename;
        }
      },
    );

    if (!success) {
      _errors.add(
        ReportedError(
          videoId: video.videoId,
          code: 'DOWNLOAD_FAILED',
          message: 'Failed to start download',
        ),
      );
    }
  }

  Future<String?> _resolveFilename(DesiredVideo video) async {
    if (video.videoFilename != null && video.videoFilename!.isNotEmpty) {
      return video.videoFilename;
    }
    if (_videoIdToFilename.containsKey(video.videoId)) {
      return _videoIdToFilename[video.videoId];
    }
    final info = await downloadManager.getDownloadInfo(video.videoId);
    return info?.filename;
  }

  bool _allVideosReady(DesiredPlaylist desired) {
    if (desired.videos.isEmpty) return false;
    for (final video in desired.videos) {
      final progress = _downloadProgress[video.videoId] ?? 0;
      if (progress < 100) return false;
    }
    return true;
  }

  Future<void> _switchToCampaign(DesiredPlaylist desired) async {
    if (desired.campaignId == null) return;
    if (_activeCampaignId == desired.campaignId) return;

    final playlist = <PlaybackItem>[];
    for (final video in desired.videos) {
      final filename = await _resolveFilename(video);
      if (filename == null) continue;
      playlist.add(
        PlaybackItem(
          videoFilename: filename,
          advertisementId: video.videoId,
          advertisementName: filename,
          trigger: 'campaign',
          campaignId: desired.campaignId,
        ),
      );
    }

    if (playlist.isEmpty) return;

    print('✅ 所有影片就緒，無縫切換至活動 ${desired.campaignId}');
    _activeCampaignId = desired.campaignId;
    onCampaignReady?.call(desired.campaignId!, playlist);
  }

  /// LRU 垃圾回收：刪除不在 desired 清單中的歷史影片
  Future<void> _garbageCollect(DesiredPlaylist desired) async {
    final keepFilenames = <String>{};
    for (final video in desired.videos) {
      final filename = video.videoFilename ?? _videoIdToFilename[video.videoId];
      if (filename != null) keepFilenames.add(filename);
    }

    final localVideos = await downloadManager.getAllDownloadedVideos();
    final accessTimes = await _loadAccessTimes();

    // 不在 desired 中的檔案，依 LRU 刪除
    final toDelete = localVideos.where((f) => !keepFilenames.contains(f)).toList();
    toDelete.sort((a, b) {
      final ta = accessTimes[a] ?? 0;
      final tb = accessTimes[b] ?? 0;
      return ta.compareTo(tb);
    });

    for (final filename in toDelete) {
      print('🗑️ LRU 垃圾回收: $filename');
      await downloadManager.deleteVideoFile(filename);
      accessTimes.remove(filename);
    }

    await _saveAccessTimes(accessTimes);
  }

  Future<Map<String, int>> _loadAccessTimes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('video_access_times');
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v as int));
  }

  Future<void> _saveAccessTimes(Map<String, int> times) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('video_access_times', jsonEncode(times));
  }

  Future<void> _publishReported() async {
    final inventory = <LocalVideoInventory>[];

    if (_currentDesired != null) {
      for (final video in _currentDesired!.videos) {
        final progress = _downloadProgress[video.videoId] ?? 0;
        LocalVideoStatus status;
        if (progress >= 100) {
          status = LocalVideoStatus.ready;
        } else if (progress > 0) {
          status = LocalVideoStatus.downloading;
        } else {
          status = LocalVideoStatus.missing;
        }

        inventory.add(
          LocalVideoInventory(
            videoId: video.videoId,
            status: status,
            progress: progress,
          ),
        );
      }
    }

    mqttManager.publishReported(
      currentCampaignId: _activeCampaignId,
      localInventory: inventory,
      errors: List.from(_errors),
    );
  }

  Future<void> publishReportedNow() => _publishReported();
}
