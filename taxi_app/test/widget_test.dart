import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_app/models/shadow_playlist.dart';

void main() {
  test('desired playlist parses content version', () {
    final playlist = DesiredPlaylist.fromJson({
      'campaign_id': 'campaign-1',
      'content_version': 'version-1',
      'updated_at': '2026-08-26T00:00:00Z',
      'videos': [
        {'video_id': 'video-1', 'url': 'https://example.test/video-1'},
      ],
    });

    expect(playlist.campaignId, 'campaign-1');
    expect(playlist.contentVersion, 'version-1');
    expect(playlist.videos.single.videoId, 'video-1');
  });
}
