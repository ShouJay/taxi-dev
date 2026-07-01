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
  // 💡 新增：背景下載完成的回調，用來通知 main.dart 刷新播放清單
  Function()? onDownloadCompleted;

  ShadowSyncService({
    required this.mqttManager,
    required this.downloadManager,
  });

  DesiredPlaylist? get currentDesired => _currentDesired;


  /// 處理後端下發的 desired 播放清單與指令
  Future<void> handleDesired(DesiredPlaylist desired) async {
    final cmdType = desired.commandType;

    if (cmdType == 'REVERT_TO_LOCAL_PLAYLIST') {
      print('🏠 收到 REVERT_TO_LOCAL 指令');
      _activeCampaignId = null;
      onRevertToLocal?.call();
      await _publishReported();
      return;
    }

    // 💡 1. 處理推播 (插播)
    if (cmdType == 'PLAY_VIDEO') {
      await _handleOverridePlay(desired);
      return;
    }

    // 💡 2. 處理獨立下載指令
    if (cmdType == 'DOWNLOAD_VIDEO') {
      await _handleDownloadCommand(desired);
      return;
    }

    // 💡 【深層特徵 Diff 攔截防線】
    if (_currentDesired != null) {
      final oldPlaylist = _currentDesired!;

      bool isBasicEqual = oldPlaylist.campaignId == desired.campaignId &&
          oldPlaylist.updatedAt == desired.updatedAt &&
          oldPlaylist.videos.length == desired.videos.length;

      if (isBasicEqual) {
        bool isVideosIdentical = true;
        for (int i = 0; i < desired.videos.length; i++) {
          if (oldPlaylist.videos[i].videoId != desired.videos[i].videoId ||
              oldPlaylist.videos[i].videoFilename != desired.videos[i].videoFilename ||
              oldPlaylist.videos[i].md5 != desired.videos[i].md5) {
            isVideosIdentical = false;
            break;
          }
        }

        if (isVideosIdentical) {
          return;
        }
      }
    }

    // 💡 【雙重防禦】空清單攔截
    if (desired.videos.isEmpty && _currentDesired?.videos.isEmpty == true && _activeCampaignId == null) {
      print('📭 兩次 desired 皆為空且已處於本地播放，忽略不重複觸發。');
      _currentDesired = desired;
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

  /// 💡 推播處理：嚴格檢查本地是否有檔案
  Future<void> _handleOverridePlay(DesiredPlaylist desired) async {
    final cmd = desired.command;
    if (cmd == null) return;

    final videoFilename = cmd['video_filename'] as String? ?? '';
    final advertisementId = cmd['advertisement_id'] as String? ?? '';
    if (videoFilename.isEmpty) return;

    final exists = await downloadManager.isVideoExists(videoFilename);

    if (exists) {
      print('🚨 [推播] 本地檔案存在，立即觸發插播: $videoFilename');
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
    } else {
      print('❌ [推播失敗] 本地找不到檔案: $videoFilename，拒絕插播並上報錯誤');

      _errors.clear();
      _errors.add(
        ReportedError(
          videoId: advertisementId.isNotEmpty ? advertisementId : 'unknown',
          code: 'FILE_NOT_FOUND',
          message: 'Push play failed: video file [$videoFilename] does not exist locally.',
        ),
      );
    }

    await _publishReported();
  }

  /// 💡 獨立下載指令處理：只下載，不打斷播放
  Future<void> _handleDownloadCommand(DesiredPlaylist desired) async {
    final cmd = desired.command;
    if (cmd == null) return;

    try {
      final downloadCmd = DownloadVideoCommand.fromJson(cmd);
      final filename = downloadCmd.videoFilename;
      print('📥 [獨立下載] 開始下載任務: ${downloadCmd.advertisementName}, 檔名: $filename');

      _videoIdToFilename[downloadCmd.advertisementId] = filename;

      if (await downloadManager.isVideoExists(filename)) {
        print('✅ [獨立下載] 影片已存在本地，忽略下載: $filename');
        _downloadProgress[downloadCmd.advertisementId] = 100;
        onDownloadCompleted?.call();
        await _publishReported();
        return;
      }

      _downloadProgress[downloadCmd.advertisementId] = 0;
      await _publishReported();

      final success = await downloadManager.startDownload(
        advertisementId: downloadCmd.advertisementId,
        expectedMd5: null,
        onProgress: (task) {
          _downloadProgress[downloadCmd.advertisementId] = task.progress;

          if (task.status == DownloadStatus.completed) {
            print('🎉 [獨立下載] 影片下載完成！通知系統加入本地清單: $filename');
            onDownloadCompleted?.call();
            publishReportedNow();
          }
        },
      );

      if (!success) {
        _errors.add(
          ReportedError(
            videoId: downloadCmd.advertisementId,
            code: 'DOWNLOAD_FAILED',
            message: 'Failed to start background download command',
          ),
        );
      }
    } catch (e) {
      print('❌ [獨立下載] 解析指令失敗: $e');
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

  Future<void> _garbageCollect(DesiredPlaylist desired) async {
    if (desired.videos.isEmpty) {
      print('⚠️ desired 影片列表為空，略過 LRU 垃圾回收以保護本地檔案。');
      return;
    }

    final keepFilenames = <String>{};

    for (final video in desired.videos) {
      if (video.videoFilename != null && video.videoFilename!.isNotEmpty) {
        keepFilenames.add(video.videoFilename!);
        _videoIdToFilename[video.videoId] = video.videoFilename!;
        continue;
      }
      if (_videoIdToFilename.containsKey(video.videoId)) {
        keepFilenames.add(_videoIdToFilename[video.videoId]!);
        continue;
      }
      try {
        final info = await downloadManager.getDownloadInfo(video.videoId);
        if (info != null && info.filename.isNotEmpty) {
          keepFilenames.add(info.filename);
          _videoIdToFilename[video.videoId] = info.filename;
        }
      } catch (e) {
        print('⚠️ LRU 盤點解析檔名失敗: $e');
      }
    }

    final localVideos = await downloadManager.getAllDownloadedVideos();
    final accessTimes = await _loadAccessTimes();

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

  void publishReportedNow() {
    _publishReported();
  }
}