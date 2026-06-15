"""
示例數據定義
定義所有測試用的示例數據
"""

from src.models import DeviceModel


class SampleData:
    """示例數據類"""
    
    @staticmethod
    def get_devices():
        """獲取設備示例數據"""
        return [
            DeviceModel.create(
                device_id="taxi-AAB-1234-rooftop",
                device_type="rooftop",
                longitude=121.5644,
                latitude=25.0340,
                groups=["taipei-taxis", "all-rooftops"]
            ),
            DeviceModel.create(
                device_id="taxi-XYZ-5678-rooftop",
                device_type="rooftop",
                longitude=121.570,
                latitude=25.030,
                groups=["taipei-taxis", "all-rooftops"]
            ),
            DeviceModel.create(
                device_id="taxi-DEF-9999-rooftop",
                device_type="rooftop",
                longitude=121.520,
                latitude=25.050,
                groups=["taipei-taxis", "premium-fleet"]
            )
        ]
    
    @staticmethod
    def get_advertisements():
        """獲取廣告示例數據"""
        # 預設不再插入示例廣告，改由管理介面自行新增
        return []
    
    @staticmethod
    def get_campaigns():
        """獲取活動示例數據"""
        # 由於預設沒有廣告資料，也同步不建立預設活動
        return []

