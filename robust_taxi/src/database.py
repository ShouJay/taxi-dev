"""
數據庫連接和初始化模組
處理 MongoDB 連接、索引創建和數據初始化
"""

from pymongo import MongoClient, GEOSPHERE
import logging

logger = logging.getLogger(__name__)


class Database:
    """數據庫管理類"""
    
    def __init__(self, uri, database_name):
        """
        初始化數據庫連接
        
        Args:
            uri: MongoDB 連接字符串
            database_name: 數據庫名稱
        """
        self.client = MongoClient(uri)
        self.db = self.client[database_name]
        
        # 獲取集合
        self.devices = self.db["devices"]
        self.advertisements = self.db["advertisements"]
        self.campaigns = self.db["campaigns"]
        
        logger.info(f"成功連接到 MongoDB 數據庫: {database_name}")
    
    def create_indexes(self):
        """
        創建地理空間索引（2dsphere）
        
        這對於高效的地理空間查詢非常重要。
        必須在使用 $geoIntersects 等地理空間運算符之前創建索引。
        
        Returns:
            bool: 是否成功創建索引
        """
        try:
            # 為 devices 集合的 last_location 字段創建 2dsphere 索引
            self.devices.create_index([("last_location", GEOSPHERE)])
            logger.info("已為 devices.last_location 創建 2dsphere 索引")
            
            # 為 campaigns 集合的 geo_fence 字段創建 2dsphere 索引
            self.campaigns.create_index([("geo_fence", GEOSPHERE)])
            logger.info("已為 campaigns.geo_fence 創建 2dsphere 索引")
            
            return True
        except Exception as e:
            logger.error(f"創建索引時出錯: {e}")
            return False
    
    def insert_sample_data(self, devices_data, advertisements_data, campaigns_data):
        """
        插入示例數據到所有集合中
        
        Args:
            devices_data: 設備數據列表
            advertisements_data: 廣告數據列表
            campaigns_data: 活動數據列表
        
        Returns:
            bool: 是否成功插入數據
        """
        try:
            # 清空現有數據
            self.devices.delete_many({})
            self.advertisements.delete_many({})
            self.campaigns.delete_many({})
            logger.info("已清空所有集合")
            
            # 插入設備數據
            if devices_data:
                self.devices.insert_many(devices_data)
                logger.info(f"已插入 {len(devices_data)} 個設備")
            
            # 插入廣告數據
            if advertisements_data:
                self.advertisements.insert_many(advertisements_data)
                logger.info(f"已插入 {len(advertisements_data)} 個廣告")
            
            # 插入活動數據
            if campaigns_data:
                self.campaigns.insert_many(campaigns_data)
                logger.info(f"已插入 {len(campaigns_data)} 個活動")
            
            return True
            
        except Exception as e:
            logger.error(f"插入示例數據時出錯: {e}")
            return False
    
    def clear_all_data(self):
        """清空所有集合的數據"""
        try:
            self.devices.delete_many({})
            self.advertisements.delete_many({})
            self.campaigns.delete_many({})
            logger.info("已清空所有集合的數據")
            return True
        except Exception as e:
            logger.error(f"清空數據時出錯: {e}")
            return False
    
    def health_check(self):
        """
        檢查數據庫連接健康狀態
        
        Returns:
            bool: 數據庫是否正常連接
        """
        try:
            self.client.admin.command('ping')
            return True
        except Exception as e:
            logger.error(f"數據庫健康檢查失敗: {e}")
            return False
    
    def close(self):
        """關閉數據庫連接"""
        self.client.close()
        logger.info("數據庫連接已關閉")

