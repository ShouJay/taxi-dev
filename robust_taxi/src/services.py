"""
業務邏輯服務層
實現廣告決策引擎的核心業務邏輯
"""

import logging
from src.models import DeviceModel, CampaignModel, HeartbeatResponse
from src.config import DEFAULT_VIDEO

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
            # 1. 查找設備信息
            device = self.db.devices.find_one({"_id": device_id})
            
            if not device:
                logger.warning(f"找不到設備: {device_id}")
                return None
            
            device_groups = device.get('groups', [])
            logger.info(f"設備 {device_id} 的分組: {device_groups}")
            
            # 2. 更新設備的最後位置
            self.db.devices.update_one(
                {"_id": device_id},
                {
                    "$set": {
                        "last_location": DeviceModel.update_location(longitude, latitude)
                    }
                }
            )
            
            # 3. 構建地理空間查詢
            point = CampaignModel.create_point_query(longitude, latitude)
            
            # 4. 查找所有與設備位置相交的地理圍欄
            matching_campaigns = self.db.campaigns.find({
                "geo_fence": {
                    "$geoIntersects": {
                        "$geometry": point
                    }
                },
                "status": "active"  # 只查詢活躍的活動
            })
            
            # 5. 過濾符合目標分組的活動
            eligible_campaigns = []
            for campaign in matching_campaigns:
                target_groups = campaign.get('target_groups', [])
                
                # 檢查設備的任一分組是否在活動的目標分組中
                if any(group in target_groups for group in device_groups):
                    eligible_campaigns.append(campaign)
                    logger.info(
                        f"找到符合條件的活動: {campaign['_id']} "
                        f"(優先級: {campaign.get('priority', 0)})"
                    )
            
            # 6. 選擇優先級最高的活動
            if not eligible_campaigns:
                logger.info("沒有找到符合條件的活動，跳過推播")
                return None
            
            selected_campaign = max(
                eligible_campaigns,
                key=lambda c: c.get('priority', 0)
            )
            logger.info(f"選中活動: {selected_campaign['_id']}")
            
            # 7. 獲取對應的廣告視頻文件名（支持多個廣告循環播放）
            # 優先使用 advertisement_ids（多個廣告列表）
            advertisement_ids = selected_campaign.get('advertisement_ids')
            
            # 如果沒有 advertisement_ids，使用舊的 advertisement_id（向後兼容）
            if not advertisement_ids:
                advertisement_id = selected_campaign.get('advertisement_id')
                if advertisement_id:
                    advertisement_ids = [advertisement_id]
                else:
                    logger.warning("活動中沒有任何廣告，跳過推播")
                    return None
            
            # 循環播放邏輯：獲取當前索引並選擇下一個廣告
            current_index = selected_campaign.get('current_ad_index', 0)
            if current_index >= len(advertisement_ids):
                current_index = 0
            
            advertisement = None
            advertisement_id = None
            selected_index = current_index
            list_len = len(advertisement_ids)
            for i in range(list_len):
                idx = (current_index + i) % list_len
                candidate_id = advertisement_ids[idx]
                candidate = self.db.advertisements.find_one({
                    "_id": candidate_id,
                    "status": "active"
                })
                if candidate:
                    advertisement = candidate
                    advertisement_id = candidate_id
                    selected_index = idx
                    break
                else:
                    logger.warning(
                        f"活動 {selected_campaign['_id']} 的廣告 {candidate_id} 無效或已下架，跳過"
                    )
            
            if not advertisement:
                logger.warning(f"活動 {selected_campaign['_id']} 沒有可用的廣告，跳過推播")
                return None
            
            # 更新下一個播放索引
            next_index = (selected_index + 1) % list_len
            self.db.campaigns.update_one(
                {"_id": selected_campaign['_id']},
                {"$set": {"current_ad_index": next_index}}
            )
            
            video_filename = advertisement.get('video_filename', DEFAULT_VIDEO)
            advertisement_name = advertisement.get('name', '未命名廣告')
            logger.info(f"決定播放廣告視頻: {video_filename} (活動: {selected_campaign['_id']}, 索引: {current_index}/{len(advertisement_ids)-1})")
            
            return {
                "video_filename": video_filename,
                "advertisement_id": advertisement_id,
                "advertisement_name": advertisement_name,
                "campaign_id": selected_campaign['_id'],
                "advertisement_ids": advertisement_ids
            }
            
        except Exception as e:
            logger.error(f"廣告決策過程出錯: {e}", exc_info=True)
            return None

