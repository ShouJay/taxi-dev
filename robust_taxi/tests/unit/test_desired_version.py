import unittest

from src.mqtt_worker import MqttWorker
from src.services import AdDecisionService


class DesiredContentVersionTests(unittest.TestCase):
    def test_dynamic_metadata_does_not_change_version(self):
        first = {
            "campaign_id": "campaign-1",
            "videos": [{
                "video_id": "video-1",
                "url": "https://example.test/video-1",
                "md5": "abc",
                "file_size": 123,
                "video_filename": "video.mp4",
            }],
            "updated_at": "2026-01-01T00:00:00Z",
        }
        second = dict(first, updated_at="2026-01-01T00:00:05Z")

        self.assertEqual(
            AdDecisionService.playlist_content_version(first),
            AdDecisionService.playlist_content_version(second),
        )

    def test_video_content_change_updates_version(self):
        first = {
            "campaign_id": "campaign-1",
            "videos": [{"video_id": "video-1", "md5": "old"}],
        }
        second = {
            "campaign_id": "campaign-1",
            "videos": [{"video_id": "video-1", "md5": "new"}],
        }

        self.assertNotEqual(
            AdDecisionService.playlist_content_version(first),
            AdDecisionService.playlist_content_version(second),
        )

    def test_video_order_is_part_of_playlist_version(self):
        first = {
            "campaign_id": "campaign-1",
            "videos": [{"video_id": "a"}, {"video_id": "b"}],
        }
        second = {
            "campaign_id": "campaign-1",
            "videos": [{"video_id": "b"}, {"video_id": "a"}],
        }

        self.assertNotEqual(
            AdDecisionService.playlist_content_version(first),
            AdDecisionService.playlist_content_version(second),
        )


class _FakeDevices:
    def __init__(self):
        self.document = {"_id": "taxi-1", "shadow": {"desired": None}}
        self.desired_update_count = 0

    def find_one(self, _query):
        return self.document

    def update_one(self, _query, update, upsert=False):
        del upsert
        desired = update.get("$set", {}).get("shadow.desired")
        if desired is not None:
            self.document["shadow"]["desired"] = desired
            self.desired_update_count += 1


class _FakeDatabase:
    def __init__(self):
        self.devices = _FakeDevices()


class _StablePlaylistService:
    playlist_content_version = staticmethod(
        AdDecisionService.playlist_content_version
    )

    def __init__(self):
        self.counter = 0

    def build_desired_playlist(self, _device_id, _lng, _lat):
        self.counter += 1
        return AdDecisionService.with_content_metadata({
            "campaign_id": "campaign-1",
            "videos": [{"video_id": "video-1", "md5": "abc"}],
        })


class _FakePublisher:
    def __init__(self, succeeds=True):
        self.succeeds = succeeds
        self.publish_count = 0

    def publish_desired(self, _device_id, _desired):
        self.publish_count += 1
        return self.succeeds


class MqttWorkerDeduplicationTests(unittest.TestCase):
    @staticmethod
    def _worker(publisher):
        worker = object.__new__(MqttWorker)
        worker.db = _FakeDatabase()
        worker.ad_service = _StablePlaylistService()
        worker.publisher = publisher
        return worker

    def test_repeated_locations_publish_desired_once(self):
        publisher = _FakePublisher()
        worker = self._worker(publisher)

        for _ in range(100):
            worker._handle_location(
                "taxi/taxi-1/location",
                {"lat": 25.03, "lng": 121.56},
            )

        self.assertEqual(publisher.publish_count, 1)
        self.assertEqual(worker.db.devices.desired_update_count, 1)

    def test_failed_publish_is_not_cached_as_delivered(self):
        publisher = _FakePublisher(succeeds=False)
        worker = self._worker(publisher)

        worker._handle_location(
            "taxi/taxi-1/location",
            {"lat": 25.03, "lng": 121.56},
        )
        worker._handle_location(
            "taxi/taxi-1/location",
            {"lat": 25.03, "lng": 121.56},
        )

        self.assertEqual(publisher.publish_count, 2)
        self.assertEqual(worker.db.devices.desired_update_count, 0)

if __name__ == "__main__":
    unittest.main()
