"""業務邏輯服務層。"""

import logging
from datetime import datetime, timezone

from src.config import API_BASE_URL, CDN_BASE_URL, DEFAULT_VIDEO
from src.models import CampaignModel, DeviceModel

logger = logging.getLogger(__name__)


class AdDecisionService:
    """廣告決策服務"""
    
    def __init__(self, database):
        """
        初始化廣告決策服務
        
        Args:
            database: Database 實例
        """
        self.db = database

    def _get_eligible_campaign(self, device_id, longitude, latitude):
        device = self.db.devices.find_one({"_id": device_id})
        if not device:
            logger.warning(f"找不到設備: {device_id}")
            return None, None

        self.db.devices.update_one(
            {"_id": device_id},
            {
                "$set": {
                    "last_location": DeviceModel.update_location(longitude, latitude)
                }
            }
        )

        point = CampaignModel.create_point_query(longitude, latitude)
        device_groups = device.get("groups", [])
        matching_campaigns = self.db.campaigns.find({
            "geo_fence": {"$geoIntersects": {"$geometry": point}},
            "status": "active"
        })

        eligible = []
        for campaign in matching_campaigns:
            target_groups = campaign.get("target_groups", [])
            if any(group in target_groups for group in device_groups):
                eligible.append(campaign)

        if not eligible:
            return device, None

        selected = max(eligible, key=lambda c: c.get("priority", 0))
        return device, selected

    def _resolve_campaign_ads(self, campaign):
        advertisement_ids = campaign.get("advertisement_ids")
        if not advertisement_ids:
            advertisement_id = campaign.get("advertisement_id")
            advertisement_ids = [advertisement_id] if advertisement_id else []

        if not advertisement_ids:
            return []

        resolved = []
        for ad_id in advertisement_ids:
            ad_doc = self.db.advertisements.find_one({"_id": ad_id, "status": "active"})
            if ad_doc:
                resolved.append((ad_id, ad_doc))
        return resolved

    def _build_download_url(self, ad_id):
        if CDN_BASE_URL:
            return f"{CDN_BASE_URL}/{ad_id}"
        return f"{API_BASE_URL}/api/v1/device/videos/{ad_id}/download"

    def build_desired_playlist(self, device_id, longitude, latitude):
        device, campaign = self._get_eligible_campaign(device_id, longitude, latitude)
        if not device:
            return None

        updated_at = datetime.now(timezone.utc).isoformat()
        if campaign is None:
            return {
                "campaign_id": None,
                "videos": [],
                "updated_at": updated_at
            }

        resolved_ads = self._resolve_campaign_ads(campaign)
        videos = []
        for ad_id, ad_doc in resolved_ads:
            videos.append({
                "video_id": ad_id,
                "url": self._build_download_url(ad_id),
                "md5": ad_doc.get("md5_hash"),
                "file_size": ad_doc.get("file_size"),
                "video_filename": ad_doc.get("video_filename")
            })

        return {
            "campaign_id": campaign["_id"],
            "videos": videos,
            "updated_at": updated_at
        }
    
    def decide_ad(self, device_id, longitude, latitude):
        """
        執行廣告決策邏輯
        
        Args:
            device_id: 設備 ID
            longitude: 經度
            latitude: 緯度
        
        Returns:
            dict: 包含 video_filename 和 advertisement_id 的字典
            {"video_filename": "...", "advertisement_id": "..."}
            或 None（無匹配廣告）
        """
        try:
            desired = self.build_desired_playlist(device_id, longitude, latitude)
            if desired is None:
                return None

            if not desired["videos"]:
                return {
                    "video_filename": DEFAULT_VIDEO,
                    "advertisement_id": None,
                    "advertisement_name": "default",
                    "campaign_id": None,
                    "advertisement_ids": []
                }

            primary = desired["videos"][0]
            advertisement = self.db.advertisements.find_one({"_id": primary["video_id"]}) or {}
            return {
                "video_filename": primary.get("video_filename", DEFAULT_VIDEO),
                "advertisement_id": primary["video_id"],
                "advertisement_name": advertisement.get("name", "未命名廣告"),
                "campaign_id": desired["campaign_id"],
                "advertisement_ids": [video["video_id"] for video in desired["videos"]]
            }
        except Exception as e:
            logger.error(f"廣告決策過程出錯: {e}", exc_info=True)
            return None

