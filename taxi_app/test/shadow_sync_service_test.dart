import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taxi_app/managers/playback_manager.dart';
import 'package:taxi_app/models/download_info.dart';
import 'package:taxi_app/models/shadow_playlist.dart';
import 'package:taxi_app/services/download_manager.dart';
import 'package:taxi_app/services/mqtt_manager.dart';
import 'package:taxi_app/services/shadow_sync_service.dart';

class _FakeDownloadManager extends DownloadManager {
  final Map<String, void Function(DownloadTask)> _callbacks = {};
  final Set<String> _readyFiles = {};

  _FakeDownloadManager() : super(baseUrl: 'http://example.test/api/v1');

  @override
  Future<List<String>> getAllDownloadedVideos() async => [];

  @override
  Future<bool> isVideoExists(String filename) async {
    return _readyFiles.contains(filename);
  }

  @override
  Future<bool> startDownload({
    required String advertisementId,
    String? expectedMd5,
    void Function(DownloadTask)? onProgress,
    void Function()? onPlaybackCheck,
  }) async {
    if (onProgress != null) _callbacks[advertisementId] = onProgress;
    return true;
  }

  void complete(String advertisementId, String filename) {
    _readyFiles.add(filename);
    final info = DownloadInfo(
      advertisementId: advertisementId,
      filename: filename,
      fileSize: 1,
      chunkSize: 1,
      totalChunks: 1,
      downloadUrl: 'http://example.test/$advertisementId',
      downloadMode: 'chunked',
    );
    _callbacks[advertisementId]?.call(
      DownloadTask(
        advertisementId: advertisementId,
        downloadInfo: info,
        status: DownloadStatus.completed,
        progress: 100,
        outputFile: File(filename),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'activates the current desired campaign after download completes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final downloads = _FakeDownloadManager();
      final playback = PlaybackManager(downloadManager: downloads);
      final mqtt = MqttManager(deviceId: 'taxi-test', brokerHost: 'localhost');
      final sync = ShadowSyncService(
        mqttManager: mqtt,
        downloadManager: downloads,
        playbackManager: playback,
      );
      final activated = <String>[];
      sync.onCampaignReady = (campaignId, _) async {
        activated.add(campaignId);
      };

      await sync.handleDesired(
        DesiredPlaylist(
          campaignId: 'campaign-1',
          contentVersion: 'version-1',
          videos: [
            DesiredVideo(
              videoId: 'video-1',
              url: 'http://example.test/video-1',
              videoFilename: 'video-1.mp4',
            ),
          ],
        ),
      );
      expect(activated, isEmpty);

      downloads.complete('video-1', 'video-1.mp4');
      await Future<void>.delayed(Duration.zero);

      expect(activated, ['campaign-1']);
    },
  );

  test('does not activate a stale campaign after leaving its fence', () async {
    SharedPreferences.setMockInitialValues({});
    final downloads = _FakeDownloadManager();
    final playback = PlaybackManager(downloadManager: downloads);
    final mqtt = MqttManager(deviceId: 'taxi-test', brokerHost: 'localhost');
    final sync = ShadowSyncService(
      mqttManager: mqtt,
      downloadManager: downloads,
      playbackManager: playback,
    );
    final activated = <String>[];
    sync.onCampaignReady = (campaignId, _) async {
      activated.add(campaignId);
    };
    sync.onRevertToLocal = () async {};

    await sync.handleDesired(
      DesiredPlaylist(
        campaignId: 'campaign-1',
        contentVersion: 'version-1',
        videos: [
          DesiredVideo(
            videoId: 'video-1',
            url: 'http://example.test/video-1',
            videoFilename: 'video-1.mp4',
          ),
        ],
      ),
    );
    await sync.handleDesired(
      DesiredPlaylist(contentVersion: 'outside-version', videos: const []),
    );

    downloads.complete('video-1', 'video-1.mp4');
    await Future<void>.delayed(Duration.zero);

    expect(activated, isEmpty);
  });
}
