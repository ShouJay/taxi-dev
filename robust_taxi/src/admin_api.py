"""
前端管理介面 API
提供給 Web 管理後台使用的 RESTful API
"""

from flask import Blueprint, request, jsonify
from datetime import datetime
from copy import deepcopy
import logging
import os
import uuid
import json
from werkzeug.utils import secure_filename

logger = logging.getLogger(__name__)

# 影片上傳配置
UPLOAD_FOLDER = 'uploads/videos'
CHUNK_FOLDER = 'uploads/chunks'
ALLOWED_EXTENSIONS = {'mp4', 'avi', 'mov', 'mkv', 'webm', 'flv', 'wmv', 'm4v'}
MAX_FILE_SIZE = 10 * 1024 * 1024 * 1024  # 10GB
CHUNK_SIZE = 10 * 1024 * 1024  # 10MB per chunk (增加分片大小)
MAX_CHUNKS = 10000  # 最大分片數 (增加分片數量限制)

# 創建 Blueprint
admin_api = Blueprint('admin_api', __name__, url_prefix='/api/v1/admin')

def allowed_file(filename):
    """檢查文件擴展名是否允許"""
    return '.' in filename and \
           filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def ensure_upload_folder():
    """確保上傳文件夾存在"""
    if not os.path.exists(UPLOAD_FOLDER):
        os.makedirs(UPLOAD_FOLDER)
    if not os.path.exists(CHUNK_FOLDER):
        os.makedirs(CHUNK_FOLDER)

def get_chunk_path(upload_id, chunk_number):
    """獲取分片文件路徑"""
    return os.path.join(CHUNK_FOLDER, f"{upload_id}_chunk_{chunk_number}")

def cleanup_chunks(upload_id):
    """清理分片文件"""
    try:
        for i in range(MAX_CHUNKS):
            chunk_path = get_chunk_path(upload_id, i)
            if os.path.exists(chunk_path):
                os.remove(chunk_path)
    except Exception as e:
        logger.warning(f"清理分片文件失敗: {e}")


def init_admin_api(
    db,
    socketio,
    device_to_sid,
    connection_stats,
    active_connections,
    device_campaign_state=None,
    device_playback_state=None
):
    """
    初始化管理 API
    
    Args:
        db: Database 實例
        socketio: SocketIO 實例
        device_to_sid: 設備到 SID 的映射
        connection_stats: 連接統計數據
        active_connections: 活動連接映射
        device_campaign_state: 設備活動快取
        device_playback_state: 設備播放狀態快取
    """
    
    # ========================================================================
    # 連接與設備管理 API
    # ========================================================================
    
    @admin_api.route('/connections', methods=['GET'])
    def get_connections():
        """
        獲取當前連接狀態
        
        前端用途：
        - 儀表板顯示在線設備
        - 設備監控頁面
        - 實時統計數據
        
        Returns:
            {
                "status": "success",
                "stats": {...},
                "active_devices": [...]
            }
        """
        try:
            active_devices = []
            
            for sid, conn_info in active_connections.items():
                active_devices.append({
                    'device_id': conn_info['device_id'],
                    'sid': sid,
                    'connected_at': conn_info['connected_at'],
                    'last_activity': conn_info['last_activity']
                })
                if device_playback_state is not None:
                    playback_state = device_playback_state.get(conn_info['device_id'])
                    if playback_state is not None:
                        active_devices[-1]['playback_state'] = deepcopy(playback_state)
            
            return jsonify({
                "status": "success",
                "stats": connection_stats,
                "active_devices": active_devices
            }), 200
        except Exception as e:
            logger.error(f"獲取連接狀態失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取連接狀態失敗"
            }), 500
    
    
    @admin_api.route('/devices', methods=['GET'])
    def get_devices():
        """
        獲取所有設備列表
        
        前端用途：
        - 設備管理頁面
        - 設備選擇器
        
        Query Parameters:
            status: 過濾狀態 (active/inactive)
            type: 過濾設備類型
        
        Returns:
            {
                "status": "success",
                "total": 5,
                "devices": [...]
            }
        """
        try:
            # 獲取查詢參數
            status_filter = request.args.get('status')
            type_filter = request.args.get('type')
            
            # 構建查詢條件
            query = {}
            if status_filter:
                query['status'] = status_filter
            if type_filter:
                query['device_type'] = type_filter
            
            # 查詢設備
            devices = list(db.devices.find(query))
            
            # 轉換 ObjectId 為字符串
            for device in devices:
                if '_id' in device:
                    device['device_id'] = device.pop('_id')
                
                # 添加在線狀態
                device['is_online'] = device.get('device_id', device.get('_id')) in device_to_sid
                
                if device_playback_state is not None:
                    playback_state = device_playback_state.get(device['device_id'])
                    if playback_state is not None:
                        device['playback_state'] = deepcopy(playback_state)
            
            return jsonify({
                "status": "success",
                "total": len(devices),
                "devices": devices
            }), 200
            
        except Exception as e:
            logger.error(f"獲取設備列表失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取設備列表失敗"
            }), 500
    
    
    @admin_api.route('/devices/<device_id>', methods=['GET'])
    def get_device_detail(device_id):
        """
        獲取設備詳情
        
        前端用途：
        - 設備詳情頁面
        - 設備信息顯示
        
        Returns:
            {
                "status": "success",
                "device": {...}
            }
        """
        try:
            device = db.devices.find_one({"_id": device_id})
            
            if not device:
                return jsonify({
                    "status": "error",
                    "message": f"設備 {device_id} 不存在"
                }), 404
            
            # 轉換 _id
            device['device_id'] = device.pop('_id')
            
            # 添加在線狀態和連接信息
            device['is_online'] = device_id in device_to_sid
            if device['is_online']:
                sid = device_to_sid[device_id]
                if sid in active_connections:
                    device['connection_info'] = active_connections[sid]
            
            if device_playback_state is not None:
                playback_state = device_playback_state.get(device_id)
                if playback_state is not None:
                    device['playback_state'] = deepcopy(playback_state)
            
            return jsonify({
                "status": "success",
                "device": device
            }), 200
            
        except Exception as e:
            logger.error(f"獲取設備詳情失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取設備詳情失敗"
            }), 500
    
    
    @admin_api.route('/devices/<device_id>', methods=['DELETE'])
    def delete_device(device_id):
        """
        刪除設備
        
        前端用途：
        - 設備管理頁面
        - 刪除不再使用的設備
        
        Returns:
            {
                "status": "success",
                "message": "設備已刪除"
            }
        """
        try:
            # 檢查設備是否存在
            device = db.devices.find_one({"_id": device_id})
            
            if not device:
                return jsonify({
                    "status": "error",
                    "message": f"設備 {device_id} 不存在"
                }), 404
            
            # 如果設備在線，先斷開連接
            if device_id in device_to_sid:
                sid = device_to_sid[device_id]
                try:
                    socketio.emit('force_disconnect', {
                        'reason': '設備已被刪除'
                    }, room=sid)
                except:
                    pass
            
            # 刪除設備
            result = db.devices.delete_one({"_id": device_id})
            
            if result.deleted_count > 0:
                logger.info(f"設備已刪除: {device_id}")
                if device_playback_state is not None and device_id in device_playback_state:
                    del device_playback_state[device_id]
                return jsonify({
                    "status": "success",
                    "message": f"設備 {device_id} 已刪除"
                }), 200
            else:
                return jsonify({
                    "status": "error",
                    "message": "刪除失敗"
                }), 500
            
        except Exception as e:
            logger.error(f"刪除設備失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "刪除設備失敗"
            }), 500
    
    @admin_api.route('/devices/playback', methods=['GET'])
    def get_devices_playback():
        """
        獲取所有設備的播放狀態
        
        前端用途：
        - 即時監控各設備播放內容
        - 儀表板播放狀態總覽
        """
        if device_playback_state is None:
            return jsonify({
                "status": "error",
                "message": "播放狀態功能未啟用"
            }), 501
        
        try:
            playback_list = []
            for device_id, playback in device_playback_state.items():
                entry = deepcopy(playback)
                entry['device_id'] = device_id
                entry['is_online'] = device_id in device_to_sid
                playback_list.append(entry)
            
            playback_list.sort(key=lambda item: item.get('updated_at', ''), reverse=True)
            
            return jsonify({
                "status": "success",
                "total": len(playback_list),
                "playback_states": playback_list
            }), 200
        except Exception as e:
            logger.error(f"獲取播放狀態列表失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取播放狀態失敗"
            }), 500
    
    
    @admin_api.route('/devices/<device_id>/playback', methods=['GET'])
    def get_device_playback(device_id):
        """
        獲取特定設備的播放狀態
        """
        if device_playback_state is None:
            return jsonify({
                "status": "error",
                "message": "播放狀態功能未啟用"
            }), 501
        
        try:
            playback_state = device_playback_state.get(device_id)
            
            if playback_state is None:
                return jsonify({
                    "status": "error",
                    "message": f"裝置 {device_id} 沒有播放記錄"
                }), 404
            
            response = deepcopy(playback_state)
            response['device_id'] = device_id
            response['is_online'] = device_id in device_to_sid
            
            return jsonify({
                "status": "success",
                "playback_state": response
            }), 200
        except Exception as e:
            logger.error(f"獲取設備播放狀態失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取播放狀態失敗"
            }), 500
    # ========================================================================
    # 廣告管理 API
    # ========================================================================
    
    @admin_api.route('/advertisements', methods=['GET'])
    def get_advertisements():
        """
        獲取廣告列表
        
        前端用途：
        - 廣告管理頁面
        - 廣告選擇器（推送時使用）
        
        Query Parameters:
            status: 過濾狀態 (active/inactive)
            type: 過濾類型
        
        Returns:
            {
                "status": "success",
                "total": 5,
                "advertisements": [...]
            }
        """
        try:
            # 獲取查詢參數
            status_filter = request.args.get('status')
            type_filter = request.args.get('type')
            
            # 構建查詢條件
            query = {}
            if status_filter:
                query['status'] = status_filter
            if type_filter:
                query['type'] = type_filter
            
            # 查詢廣告
            ads = list(db.advertisements.find(query))
            
            # 轉換 ObjectId 並添加影片信息
            for ad in ads:
                if '_id' in ad:
                    ad['advertisement_id'] = ad.pop('_id')
                
                # 添加影片文件存在狀態
                video_path = ad.get('video_path')
                ad['file_exists'] = video_path and os.path.exists(video_path) if video_path else False
            
            return jsonify({
                "status": "success",
                "total": len(ads),
                "advertisements": ads
            }), 200
            
        except Exception as e:
            logger.error(f"獲取廣告列表失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取廣告列表失敗"
            }), 500
    
    
    @admin_api.route('/advertisements/<ad_id>', methods=['GET'])
    def get_advertisement_detail(ad_id):
        """
        獲取廣告詳情
        
        前端用途：
        - 廣告詳情頁面
        - 廣告預覽
        
        Returns:
            {
                "status": "success",
                "advertisement": {...}
            }
        """
        try:
            ad = db.advertisements.find_one({"_id": ad_id})
            
            if not ad:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {ad_id} 不存在"
                }), 404
            
            # 轉換 _id
            ad['advertisement_id'] = ad.pop('_id')
            
            # 添加影片文件存在狀態
            video_path = ad.get('video_path')
            ad['file_exists'] = video_path and os.path.exists(video_path) if video_path else False
            
            return jsonify({
                "status": "success",
                "advertisement": ad
            }), 200
            
        except Exception as e:
            logger.error(f"獲取廣告詳情失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取廣告詳情失敗"
            }), 500
    
    
    # ========================================================================
    # 活動管理 API
    # ========================================================================
    
    @admin_api.route('/campaigns', methods=['GET'])
    def get_campaigns():
        """
        獲取活動列表
        
        前端用途：
        - 活動管理頁面
        - 活動列表展示
        
        Query Parameters:
            status: 過濾狀態 (active/inactive)
        
        Returns:
            {
                "status": "success",
                "total": 5,
                "campaigns": [...]
            }
        """
        try:
            # 獲取查詢參數
            status_filter = request.args.get('status')
            
            # 構建查詢條件
            query = {}
            if status_filter:
                query['status'] = status_filter
            
            # 查詢活動
            campaigns = list(db.campaigns.find(query))
            
            # 轉換 ObjectId 並關聯廣告信息
            for campaign in campaigns:
                if '_id' in campaign:
                    campaign['campaign_id'] = campaign.pop('_id')
                
                # 獲取關聯的廣告信息（支持多個廣告）
                advertisement_ids = campaign.get('advertisement_ids', [])
                if not advertisement_ids and 'advertisement_id' in campaign:
                    advertisement_ids = [campaign['advertisement_id']]
                
                campaign['advertisement_names'] = []
                campaign['advertisement_videos'] = []
                for ad_id in advertisement_ids:
                    ad = db.advertisements.find_one({"_id": ad_id})
                    if ad:
                        campaign['advertisement_names'].append(ad.get('name', ''))
                        campaign['advertisement_videos'].append(ad.get('video_filename', ''))
                
                # 向後兼容：保留單個廣告的欄位
                if len(advertisement_ids) > 0:
                    campaign['advertisement_id'] = advertisement_ids[0]
                    if len(campaign['advertisement_names']) > 0:
                        campaign['advertisement_name'] = campaign['advertisement_names'][0]
            
            return jsonify({
                "status": "success",
                "total": len(campaigns),
                "campaigns": campaigns
            }), 200
            
        except Exception as e:
            logger.error(f"獲取活動列表失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取活動列表失敗"
            }), 500
    
    
    @admin_api.route('/campaigns', methods=['POST'])
    def create_campaign():
        """
        創建新活動
        
        前端用途：
        - 活動創建頁面
        
        Request Body:
            {
                "campaign_id": "camp-001",  // 可選，不提供則自動生成
                "name": "活動名稱",
                "advertisement_ids": ["adv-001", "adv-002"],  // 廣告ID列表（支持多個）
                "priority": 5,
                "target_groups": ["general"],
                "center_location": {
                    "longitude": 121.5645,
                    "latitude": 25.0330
                },
                "radius_meters": 500  // 範圍半徑（公尺）
            }
        
        Returns:
            {
                "status": "success",
                "campaign_id": "...",
                "message": "活動創建成功"
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            campaign_id = data.get('campaign_id')
            name = data.get('name')
            advertisement_ids = data.get('advertisement_ids', [])
            priority = data.get('priority', 5)
            target_groups = data.get('target_groups', ['general'])
            center_location = data.get('center_location')
            radius_meters = data.get('radius_meters', 500)
            
            # 驗證必要欄位
            if not name:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: name"
                }), 400
            
            if not advertisement_ids or len(advertisement_ids) == 0:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: advertisement_ids（至少需要一個廣告）"
                }), 400
            
            if not center_location:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: center_location"
                }), 400
            
            center_longitude = center_location.get('longitude')
            center_latitude = center_location.get('latitude')
            
            if center_longitude is None or center_latitude is None:
                return jsonify({
                    "status": "error",
                    "message": "center_location 必須包含 longitude 和 latitude"
                }), 400
            
            # 驗證經緯度範圍
            if not (-180 <= center_longitude <= 180) or not (-90 <= center_latitude <= 90):
                return jsonify({
                    "status": "error",
                    "message": "經緯度範圍無效"
                }), 400
            
            # 驗證廣告是否存在
            for ad_id in advertisement_ids:
                ad = db.advertisements.find_one({"_id": ad_id})
                if not ad:
                    return jsonify({
                        "status": "error",
                        "message": f"廣告 {ad_id} 不存在"
                    }), 404
            
            # 如果沒有提供 campaign_id，自動生成
            if not campaign_id:
                import uuid
                campaign_id = f"camp-{uuid.uuid4().hex[:8]}"
            
            # 檢查活動ID是否已存在
            existing = db.campaigns.find_one({"_id": campaign_id})
            if existing:
                return jsonify({
                    "status": "error",
                    "message": f"活動 {campaign_id} 已存在"
                }), 400
            
            # 創建活動
            from src.models import CampaignModel
            campaign = CampaignModel.create_with_center(
                campaign_id=campaign_id,
                name=name,
                advertisement_ids=advertisement_ids,
                priority=priority,
                target_groups=target_groups,
                center_longitude=center_longitude,
                center_latitude=center_latitude,
                radius_meters=radius_meters
            )
            
            db.campaigns.insert_one(campaign)
            
            logger.info(f"新活動已創建: {campaign_id}, 中心點: ({center_longitude}, {center_latitude}), 半徑: {radius_meters}公尺")
            
            return jsonify({
                "status": "success",
                "message": "活動創建成功",
                "campaign_id": campaign_id,
                "campaign": campaign
            }), 201
            
        except Exception as e:
            logger.error(f"創建活動失敗: {e}")
            return jsonify({
                "status": "error",
                "message": f"創建活動失敗: {str(e)}"
            }), 500
    
    
    @admin_api.route('/campaigns/<campaign_id>', methods=['GET'])
    def get_campaign_detail(campaign_id):
        """
        獲取活動詳情
        
        前端用途：
        - 活動詳情頁面
        - 活動編輯表單
        
        Returns:
            {
                "status": "success",
                "campaign": {...}
            }
        """
        try:
            campaign = db.campaigns.find_one({"_id": campaign_id})
            
            if not campaign:
                return jsonify({
                    "status": "error",
                    "message": f"活動 {campaign_id} 不存在"
                }), 404
            
            # 轉換 _id
            campaign['campaign_id'] = campaign.pop('_id')
            
            # 獲取關聯的廣告詳細信息
            advertisement_ids = campaign.get('advertisement_ids', [])
            if not advertisement_ids and 'advertisement_id' in campaign:
                advertisement_ids = [campaign['advertisement_id']]
            
            campaign['advertisements'] = []
            for ad_id in advertisement_ids:
                ad = db.advertisements.find_one({"_id": ad_id})
                if ad:
                    ad_info = {
                        "advertisement_id": ad['_id'],
                        "name": ad.get('name', ''),
                        "video_filename": ad.get('video_filename', ''),
                        "file_exists": ad.get('video_path') and os.path.exists(ad.get('video_path', '')) if ad.get('video_path') else False
                    }
                    campaign['advertisements'].append(ad_info)
            
            return jsonify({
                "status": "success",
                "campaign": campaign
            }), 200
            
        except Exception as e:
            logger.error(f"獲取活動詳情失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取活動詳情失敗"
            }), 500
    
    
    @admin_api.route('/campaigns/<campaign_id>', methods=['DELETE'])
    def delete_campaign(campaign_id):
        """
        刪除活動
        
        前端用途：
        - 活動管理頁面
        - 刪除不需要的活動
        """
        try:
            campaign = db.campaigns.find_one({"_id": campaign_id})
            
            if not campaign:
                return jsonify({
                    "status": "error",
                    "message": f"活動 {campaign_id} 不存在"
                }), 404
            
            result = db.campaigns.delete_one({"_id": campaign_id})
            
            if result.deleted_count == 0:
                return jsonify({
                    "status": "error",
                    "message": f"刪除活動 {campaign_id} 失敗"
                }), 500
            
            affected_devices = []
            
            if device_campaign_state is not None:
                affected_devices = [
                    device_id for device_id, current_campaign in device_campaign_state.items()
                    if current_campaign == campaign_id
                ]
                
                for device_id in affected_devices:
                    device_campaign_state[device_id] = None
                    sid = device_to_sid.get(device_id)
                    
                    if sid:
                        try:
                            socketio.emit('revert_to_local_playlist', {
                                "command": "REVERT_TO_LOCAL_PLAYLIST",
                                "reason": "campaign_deleted",
                                "campaign_id": campaign_id,
                                "timestamp": datetime.now().isoformat()
                            }, room=sid)
                        except Exception as emit_error:
                            logger.error(f"通知設備 {device_id} 活動刪除時出錯: {emit_error}")
            
            logger.info(f"活動已刪除: {campaign_id}，受影響設備: {affected_devices}")
            
            return jsonify({
                "status": "success",
                "message": f"活動 {campaign_id} 已刪除",
                "affected_devices": affected_devices
            }), 200
        
        except Exception as e:
            logger.error(f"刪除活動失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "刪除活動失敗"
            }), 500
    
    
    # ========================================================================
    # 設備註冊 API（新增）
    # ========================================================================
    
    @admin_api.route('/devices', methods=['POST'])
    def create_device():
        """
        註冊新設備
        
        前端用途：
        - 設備註冊頁面
        
        Request Body:
            {
                "device_id": "taxi-NEW-001-rooftop",
                "device_type": "rooftop_display",
                "groups": ["general"]
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            device_id = data.get('device_id')
            device_type = data.get('device_type', 'rooftop_display')
            groups = data.get('groups', ['general'])
            
            if not device_id:
                return jsonify({
                    "status": "error",
                    "message": "缺少 device_id"
                }), 400
            
            # 檢查設備是否已存在
            existing = db.devices.find_one({"_id": device_id})
            if existing:
                return jsonify({
                    "status": "error",
                    "message": f"設備 {device_id} 已存在"
                }), 400
            
            # 創建設備
            device = {
                "_id": device_id,
                "device_type": device_type,
                "groups": groups,
                "last_location": {
                    "type": "Point",
                    "coordinates": [121.5200, 25.0400]  # 預設台北市中心
                },
                "status": "active",
                "created_at": datetime.now().isoformat()
            }
            
            db.devices.insert_one(device)
            
            logger.info(f"新設備已註冊: {device_id}")
            
            return jsonify({
                "status": "success",
                "message": "設備註冊成功",
                "device_id": device_id
            }), 201
            
        except Exception as e:
            logger.error(f"註冊設備失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "註冊設備失敗"
            }), 500
    
    
    # ========================================================================
    # 廣告 CRUD API（新增）
    # ========================================================================
    
    @admin_api.route('/advertisements', methods=['POST'])
    def create_advertisement():
        """
        新增廣告
        
        前端用途：
        - 新增廣告頁面
        
        Request Body:
            {
                "advertisement_id": "adv-new-001",
                "name": "新廣告名稱",
                "video_filename": "video.mp4",
                "trigger_location": {
                    "longitude": 121.5645,
                    "latitude": 25.0330
                },
                "trigger_radius": 500
            }
        
        說明：
        - trigger_location: 可選，IP 中心點（經緯度）
        - trigger_radius: 可選，觸發半徑（公尺），預設 500
        - 如果沒有 trigger_location，則不會自動插播
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            ad_id = data.get('advertisement_id')
            name = data.get('name')
            video_filename = data.get('video_filename')
            video_path = data.get('video_path')
            file_size = data.get('file_size')
            duration = data.get('duration')
            trigger_location = data.get('trigger_location')  # {longitude, latitude}
            trigger_radius = data.get('trigger_radius', 500)  # 預設 500 公尺
            
            if not ad_id or not name:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: advertisement_id, name"
                }), 400
            
            # 如果沒有提供video_filename，使用默認值
            if not video_filename:
                video_filename = "default_ad.mp4"
            
            # 檢查廣告是否已存在
            existing = db.advertisements.find_one({"_id": ad_id})
            if existing:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {ad_id} 已存在"
                }), 400
            
            # 創建廣告
            from src.models import AdvertisementModel
            advertisement = AdvertisementModel.create(
                ad_id=ad_id,
                name=name,
                video_filename=video_filename,
                video_path=video_path,
                file_size=file_size,
                duration=duration,
                upload_date=datetime.now().isoformat()
            )
            
            # 添加其他欄位
            advertisement.update({
                "type": data.get('type', 'general'),
                "priority": data.get('priority', 5),
                "target_groups": data.get('target_groups', ['general'])
            })
            
            # 如果有觸發位置，添加到廣告
            if trigger_location:
                longitude = trigger_location.get('longitude')
                latitude = trigger_location.get('latitude')
                
                if longitude and latitude:
                    advertisement['trigger_location'] = {
                        "type": "Point",
                        "coordinates": [longitude, latitude]
                    }
                    advertisement['trigger_radius'] = trigger_radius
            
            db.advertisements.insert_one(advertisement)
            
            # 如果有觸發位置，自動創建對應的活動
            if trigger_location and trigger_location.get('longitude') and trigger_location.get('latitude'):
                campaign_id = f"camp-auto-{ad_id}"
                
                # 計算圓形地理圍欄（近似為多邊形）
                import math
                
                longitude = trigger_location['longitude']
                latitude = trigger_location['latitude']
                radius_km = trigger_radius / 1000  # 轉換為公里
                
                # 生成圓形的近似多邊形（16 個點）
                points = []
                for i in range(16):
                    angle = (2 * math.pi * i) / 16
                    # 經緯度偏移計算（簡化版）
                    dx = radius_km / 111.32 * math.cos(angle)  # 經度
                    dy = radius_km / 110.574 * math.sin(angle)  # 緯度
                    points.append([longitude + dx, latitude + dy])
                
                # 閉合多邊形
                points.append(points[0])
                
                campaign = {
                    "_id": campaign_id,
                    "name": f"自動活動 - {name}",
                    "advertisement_id": ad_id,
                    "priority": advertisement['priority'],
                    "target_groups": advertisement['target_groups'],
                    "geo_fence": {
                        "type": "Polygon",
                        "coordinates": [points]
                    },
                    "trigger_type": "auto_proximity",  # 標記為自動觸發
                    "trigger_radius": trigger_radius,
                    "status": "active",
                    "created_at": datetime.now().isoformat()
                }
                
                db.campaigns.insert_one(campaign)
                logger.info(f"自動創建活動: {campaign_id}，半徑 {trigger_radius} 公尺")
            
            logger.info(f"新廣告已創建: {ad_id}")
            
            return jsonify({
                "status": "success",
                "message": "廣告創建成功",
                "advertisement_id": ad_id,
                "auto_campaign_created": trigger_location is not None
            }), 201
            
        except Exception as e:
            logger.error(f"創建廣告失敗: {e}")
            return jsonify({
                "status": "error",
                "message": f"創建廣告失敗: {str(e)}"
            }), 500
    
    
    @admin_api.route('/advertisements/<ad_id>', methods=['PUT'])
    def update_advertisement(ad_id):
        """
        更新廣告
        
        前端用途：
        - 編輯廣告頁面
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            # 檢查廣告是否存在
            existing = db.advertisements.find_one({"_id": ad_id})
            if not existing:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {ad_id} 不存在"
                }), 404
            
            # 準備更新數據
            update_data = {}
            
            if 'name' in data:
                update_data['name'] = data['name']
            if 'video_filename' in data:
                update_data['video_filename'] = data['video_filename']
            if 'type' in data:
                update_data['type'] = data['type']
            if 'priority' in data:
                update_data['priority'] = data['priority']
            if 'target_groups' in data:
                update_data['target_groups'] = data['target_groups']
            if 'status' in data:
                update_data['status'] = data['status']
            
            # 處理觸發位置更新
            if 'trigger_location' in data:
                trigger_location = data['trigger_location']
                if trigger_location and trigger_location.get('longitude') and trigger_location.get('latitude'):
                    update_data['trigger_location'] = {
                        "type": "Point",
                        "coordinates": [trigger_location['longitude'], trigger_location['latitude']]
                    }
                    update_data['trigger_radius'] = data.get('trigger_radius', 500)
                else:
                    # 移除觸發位置
                    update_data['trigger_location'] = None
                    update_data['trigger_radius'] = None
            
            update_data['updated_at'] = datetime.now().isoformat()
            
            # 更新廣告
            db.advertisements.update_one(
                {"_id": ad_id},
                {"$set": update_data}
            )
            
            logger.info(f"廣告已更新: {ad_id}")
            
            return jsonify({
                "status": "success",
                "message": "廣告更新成功"
            }), 200
            
        except Exception as e:
            logger.error(f"更新廣告失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "更新廣告失敗"
            }), 500
    
    
    @admin_api.route('/advertisements/<ad_id>', methods=['DELETE'])
    def delete_advertisement(ad_id):
        """
        刪除廣告（硬刪除，包括文件和數據庫記錄）
        
        前端用途：
        - 廣告管理頁面
        """
        try:
            # 檢查廣告是否存在
            existing = db.advertisements.find_one({"_id": ad_id})
            if not existing:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {ad_id} 不存在"
                }), 404
            
            # 刪除影片文件
            video_path = existing.get('video_path')
            if video_path and os.path.exists(video_path):
                try:
                    os.remove(video_path)
                    logger.info(f"影片文件已刪除: {video_path}")
                except Exception as e:
                    logger.warning(f"刪除影片文件失敗: {e}")
            
            # 刪除廣告數據庫記錄
            db.advertisements.delete_one({"_id": ad_id})
            
            # 同時刪除相關的活動
            db.campaigns.delete_many({"advertisement_id": ad_id})
            
            logger.info(f"廣告已刪除: {ad_id}")
            
            return jsonify({
                "status": "success",
                "message": "廣告刪除成功"
            }), 200
            
        except Exception as e:
            logger.error(f"刪除廣告失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "刪除廣告失敗"
            }), 500
    
    
    # ========================================================================
    # 分片上傳 API
    # ========================================================================
    
    @admin_api.route('/videos/chunked/init', methods=['POST'])
    def init_chunked_upload():
        """
        初始化分片上傳
        
        前端用途：
        - 開始分片上傳前調用
        
        Request Body:
            {
                "filename": "video.mp4",
                "total_size": 123456789,
                "total_chunks": 25,
                "name": "廣告名稱",
                "advertisement_id": "adv-001" (可選)
            }
        
        Returns:
            {
                "status": "success",
                "upload_id": "uuid-string",
                "chunk_size": 5242880,
                "message": "分片上傳已初始化"
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            filename = data.get('filename')
            total_size = data.get('total_size')
            total_chunks = data.get('total_chunks')
            name = data.get('name')
            advertisement_id = data.get('advertisement_id')
            
            if not all([filename, total_size, total_chunks, name]):
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: filename, total_size, total_chunks, name"
                }), 400
            
            # 檢查文件類型
            if not allowed_file(filename):
                return jsonify({
                    "status": "error",
                    "message": f"不支持的文件類型。支持的格式: {', '.join(ALLOWED_EXTENSIONS)}"
                }), 400
            
            # 檢查文件大小
            if total_size > MAX_FILE_SIZE:
                return jsonify({
                    "status": "error",
                    "message": f"文件太大，最大允許 {MAX_FILE_SIZE // (1024*1024*1024)}GB"
                }), 400
            
            # 檢查分片數量
            if total_chunks > MAX_CHUNKS:
                return jsonify({
                    "status": "error",
                    "message": f"分片數量過多，最大允許 {MAX_CHUNKS} 個分片"
                }), 400
            
            # 生成上傳ID
            upload_id = str(uuid.uuid4())
            
            # 如果沒有提供廣告ID，自動生成
            if not advertisement_id:
                advertisement_id = f"adv-{uuid.uuid4().hex[:8]}"
            
            # 檢查廣告ID是否已存在，如果存在則生成新的
            original_ad_id = advertisement_id
            counter = 1
            while db.advertisements.find_one({"_id": advertisement_id}):
                advertisement_id = f"{original_ad_id}-{counter}"
                counter += 1
                if counter > 100:  # 防止無限循環
                    advertisement_id = f"adv-{uuid.uuid4().hex[:8]}"
                    break
            
            if advertisement_id != original_ad_id:
                logger.info(f"廣告ID衝突，使用新ID: {original_ad_id} -> {advertisement_id}")
            
            # 確保文件夾存在
            ensure_upload_folder()
            
            # 保存上傳會話信息
            upload_session = {
                "upload_id": upload_id,
                "filename": filename,
                "total_size": total_size,
                "total_chunks": total_chunks,
                "received_chunks": [],
                "name": name,
                "advertisement_id": advertisement_id,
                "status": "uploading",
                "created_at": datetime.now().isoformat()
            }
            
            # 這裡可以將上傳會話保存到數據庫或內存中
            # 為了簡化，我們使用文件系統存儲會話信息
            session_file = os.path.join(CHUNK_FOLDER, f"{upload_id}_session.json")
            with open(session_file, 'w', encoding='utf-8') as f:
                json.dump(upload_session, f, ensure_ascii=False, indent=2)
            
            logger.info(f"分片上傳已初始化: {upload_id}, 文件: {filename}, 大小: {total_size}")
            
            return jsonify({
                "status": "success",
                "upload_id": upload_id,
                "chunk_size": CHUNK_SIZE,
                "message": "分片上傳已初始化"
            }), 200
            
        except Exception as e:
            logger.error(f"初始化分片上傳失敗: {e}")
            return jsonify({
                "status": "error",
                "message": f"初始化分片上傳失敗: {str(e)}"
            }), 500
    
    
    @admin_api.route('/videos/chunked/upload', methods=['POST'])
    def upload_chunk():
        """
        上傳分片
        
        前端用途：
        - 上傳單個分片
        
        Request:
            - multipart/form-data
            - upload_id: 上傳ID
            - chunk_number: 分片編號
            - chunk: 分片數據
        
        Returns:
            {
                "status": "success",
                "upload_id": "uuid-string",
                "chunk_number": 1,
                "received_chunks": [1],
                "total_chunks": 25,
                "progress": 4.0
            }
        """
        try:
            upload_id = request.form.get('upload_id')
            chunk_number = request.form.get('chunk_number')
            chunk_data = request.files.get('chunk')
            
            if not all([upload_id, chunk_number, chunk_data]):
                return jsonify({
                    "status": "error",
                    "message": "缺少必要參數: upload_id, chunk_number, chunk"
                }), 400
            
            chunk_number = int(chunk_number)
            
            # 讀取上傳會話
            session_file = os.path.join(CHUNK_FOLDER, f"{upload_id}_session.json")
            if not os.path.exists(session_file):
                return jsonify({
                    "status": "error",
                    "message": "上傳會話不存在或已過期"
                }), 404
            
            with open(session_file, 'r', encoding='utf-8') as f:
                upload_session = json.load(f)
            
            # 檢查分片編號
            if chunk_number >= upload_session['total_chunks']:
                return jsonify({
                    "status": "error",
                    "message": f"分片編號超出範圍: {chunk_number} >= {upload_session['total_chunks']}"
                }), 400
            
            # 保存分片
            chunk_path = get_chunk_path(upload_id, chunk_number)
            try:
                chunk_data.save(chunk_path)
                logger.info(f"分片保存成功: {chunk_path}")
            except Exception as save_error:
                logger.error(f"保存分片失敗: {save_error}")
                return jsonify({
                    "status": "error",
                    "message": f"保存分片失敗: {str(save_error)}"
                }), 500
            
            # 更新會話
            if chunk_number not in upload_session['received_chunks']:
                upload_session['received_chunks'].append(chunk_number)
                upload_session['received_chunks'].sort()
            
            # 保存更新的會話
            with open(session_file, 'w', encoding='utf-8') as f:
                json.dump(upload_session, f, ensure_ascii=False, indent=2)
            
            progress = (len(upload_session['received_chunks']) / upload_session['total_chunks']) * 100
            
            logger.info(f"分片上傳: {upload_id}, 分片 {chunk_number}/{upload_session['total_chunks']}")
            
            return jsonify({
                "status": "success",
                "upload_id": upload_id,
                "chunk_number": chunk_number,
                "received_chunks": upload_session['received_chunks'],
                "total_chunks": upload_session['total_chunks'],
                "progress": round(progress, 2)
            }), 200
            
        except Exception as e:
            logger.error(f"分片上傳失敗: {e}")
            return jsonify({
                "status": "error",
                "message": f"分片上傳失敗: {str(e)}"
            }), 500
    
    
    @admin_api.route('/videos/chunked/complete', methods=['POST'])
    def complete_chunked_upload():
        """
        完成分片上傳
        
        前端用途：
        - 所有分片上傳完成後調用
        
        Request Body:
            {
                "upload_id": "uuid-string"
            }
        
        Returns:
            {
                "status": "success",
                "message": "分片上傳完成",
                "video_info": {...}
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            upload_id = data.get('upload_id')
            
            if not upload_id:
                return jsonify({
                    "status": "error",
                    "message": "缺少 upload_id"
                }), 400
            
            # 讀取上傳會話
            session_file = os.path.join(CHUNK_FOLDER, f"{upload_id}_session.json")
            if not os.path.exists(session_file):
                return jsonify({
                    "status": "error",
                    "message": "上傳會話不存在或已過期"
                }), 404
            
            with open(session_file, 'r', encoding='utf-8') as f:
                upload_session = json.load(f)
            
            # 檢查是否所有分片都已上傳
            expected_chunks = list(range(upload_session['total_chunks']))
            received_chunks = upload_session['received_chunks']
            
            if set(expected_chunks) != set(received_chunks):
                missing_chunks = set(expected_chunks) - set(received_chunks)
                return jsonify({
                    "status": "error",
                    "message": f"缺少分片: {sorted(missing_chunks)}"
                }), 400
            
            # 合併分片
            final_filename = f"{uuid.uuid4()}.{upload_session['filename'].rsplit('.', 1)[1].lower()}"
            final_path = os.path.join(UPLOAD_FOLDER, final_filename)
            
            try:
                with open(final_path, 'wb') as final_file:
                    for chunk_number in range(upload_session['total_chunks']):
                        chunk_path = get_chunk_path(upload_id, chunk_number)
                        if os.path.exists(chunk_path):
                            try:
                                with open(chunk_path, 'rb') as chunk_file:
                                    chunk_data = chunk_file.read()
                                    final_file.write(chunk_data)
                                logger.debug(f"合併分片 {chunk_number} 成功")
                            except Exception as read_error:
                                logger.error(f"讀取分片 {chunk_number} 失敗: {read_error}")
                                return jsonify({
                                    "status": "error",
                                    "message": f"讀取分片 {chunk_number} 失敗: {str(read_error)}"
                                }), 500
                        else:
                            logger.error(f"分片文件不存在: {chunk_path}")
                            return jsonify({
                                "status": "error",
                                "message": f"分片文件不存在: {chunk_number}"
                            }), 500
                            
                logger.info(f"分片合併完成: {final_path}")
                
            except Exception as merge_error:
                logger.error(f"合併分片失敗: {merge_error}")
                # 清理可能創建的不完整文件
                if os.path.exists(final_path):
                    try:
                        os.remove(final_path)
                    except:
                        pass
                return jsonify({
                    "status": "error",
                    "message": f"合併分片失敗: {str(merge_error)}"
                }), 500
            
            # 獲取最終文件大小
            file_size = os.path.getsize(final_path)
            
            # 創建廣告記錄
            from src.models import AdvertisementModel
            advertisement = AdvertisementModel.create(
                ad_id=upload_session['advertisement_id'],
                name=upload_session['name'],
                video_filename=final_filename,
                video_path=final_path,
                file_size=file_size,
                upload_date=datetime.now().isoformat()
            )
            
            # 保存到數據庫
            db.advertisements.insert_one(advertisement)
            
            # 清理分片文件和會話
            cleanup_chunks(upload_id)
            if os.path.exists(session_file):
                os.remove(session_file)
            
            logger.info(f"分片上傳完成: {upload_session['advertisement_id']}, 文件: {final_filename}, 大小: {file_size}")
            
            return jsonify({
                "status": "success",
                "message": "分片上傳完成",
                "video_info": {
                    "filename": final_filename,
                    "path": final_path,
                    "size": file_size,
                    "advertisement_id": upload_session['advertisement_id'],
                    "name": upload_session['name']
                }
            }), 201
            
        except Exception as e:
            logger.error(f"完成分片上傳失敗: {e}")
            return jsonify({
                "status": "error",
                "message": f"完成分片上傳失敗: {str(e)}"
            }), 500
    
    
    @admin_api.route('/videos/chunked/cancel', methods=['POST'])
    def cancel_chunked_upload():
        """
        取消分片上傳
        
        前端用途：
        - 取消正在進行的分片上傳
        
        Request Body:
            {
                "upload_id": "uuid-string"
            }
        
        Returns:
            {
                "status": "success",
                "message": "分片上傳已取消"
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            upload_id = data.get('upload_id')
            
            if not upload_id:
                return jsonify({
                    "status": "error",
                    "message": "缺少 upload_id"
                }), 400
            
            # 清理分片文件和會話
            cleanup_chunks(upload_id)
            
            session_file = os.path.join(CHUNK_FOLDER, f"{upload_id}_session.json")
            if os.path.exists(session_file):
                os.remove(session_file)
            
            logger.info(f"分片上傳已取消: {upload_id}")
            
            return jsonify({
                "status": "success",
                "message": "分片上傳已取消"
            }), 200
            
        except Exception as e:
            logger.error(f"取消分片上傳失敗: {e}")
            return jsonify({
                "status": "error",
                "message": f"取消分片上傳失敗: {str(e)}"
            }), 500
    
    
    # ========================================================================
    # 影片上傳 API (傳統方式，保留向後兼容)
    # ========================================================================
    
    @admin_api.route('/videos/upload', methods=['POST'])
    def upload_video():
        """
        上傳影片文件 - 重定向到分片上傳
        
        為了保持向後兼容，此端點現在會返回錯誤並指引使用分片上傳
        """
        return jsonify({
            "status": "error",
            "message": "請使用分片上傳接口。此接口已被廢棄。",
            "redirect_to": {
                "init": "/api/v1/admin/videos/chunked/init",
                "upload": "/api/v1/admin/videos/chunked/upload",
                "complete": "/api/v1/admin/videos/chunked/complete"
            }
        }), 400
    
    
    @admin_api.route('/videos/<advertisement_id>', methods=['GET'])
    def get_video_info(advertisement_id):
        """
        獲取影片信息
        
        前端用途：
        - 影片預覽
        - 影片詳情頁面
        
        Returns:
            {
                "status": "success",
                "video_info": {...}
            }
        """
        try:
            advertisement = db.advertisements.find_one({"_id": advertisement_id})
            
            if not advertisement:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {advertisement_id} 不存在"
                }), 404
            
            # 檢查文件是否存在
            video_path = advertisement.get('video_path')
            file_exists = video_path and os.path.exists(video_path)
            
            video_info = {
                "advertisement_id": advertisement_id,
                "name": advertisement.get('name', ''),
                "filename": advertisement.get('video_filename', ''),
                "path": video_path,
                "size": advertisement.get('file_size', 0),
                "duration": advertisement.get('duration'),
                "status": advertisement.get('status', 'active'),
                "created_at": advertisement.get('created_at'),
                "file_exists": file_exists
            }
            
            return jsonify({
                "status": "success",
                "video_info": video_info
            }), 200
            
        except Exception as e:
            logger.error(f"獲取影片信息失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取影片信息失敗"
            }), 500
    
    
    @admin_api.route('/videos/<advertisement_id>/download', methods=['GET'])
    def download_video(advertisement_id):
        """
        下載影片文件（支持分片下載）
        
        前端用途：
        - 影片下載
        - 影片預覽
        
        Query Parameters:
            chunked: 是否使用分片下載 (true/false)
            chunk_size: 分片大小 (bytes)
        
        Returns:
            - 影片文件流或分片信息
        """
        try:
            advertisement = db.advertisements.find_one({"_id": advertisement_id})
            
            if not advertisement:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {advertisement_id} 不存在"
                }), 404
            
            video_path = advertisement.get('video_path')
            
            if not video_path or not os.path.exists(video_path):
                return jsonify({
                    "status": "error",
                    "message": "影片文件不存在"
                }), 404
            
            # 檢查是否使用分片下載
            use_chunked = request.args.get('chunked', 'false').lower() == 'true'
            chunk_size = int(request.args.get('chunk_size', CHUNK_SIZE))
            
            if use_chunked:
                # 返回分片下載信息
                file_size = os.path.getsize(video_path)
                total_chunks = (file_size + chunk_size - 1) // chunk_size
                
                return jsonify({
                    "status": "success",
                    "download_info": {
                        "advertisement_id": advertisement_id,
                        "filename": advertisement.get('video_filename', 'video.mp4'),
                        "file_size": file_size,
                        "chunk_size": chunk_size,
                        "total_chunks": total_chunks,
                        "download_url": f"/api/v1/admin/videos/{advertisement_id}/chunk"
                    }
                }), 200
            else:
                # 傳統下載方式
                from flask import send_file
                
                return send_file(
                    video_path,
                    as_attachment=True,
                    download_name=advertisement.get('video_filename', 'video.mp4')
                )
            
        except Exception as e:
            logger.error(f"下載影片失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "下載影片失敗"
            }), 500
    
    
    @admin_api.route('/videos/<advertisement_id>/chunk', methods=['GET'])
    def download_video_chunk(advertisement_id):
        """
        下載影片分片
        
        前端用途：
        - 分片下載影片
        
        Query Parameters:
            chunk: 分片編號 (從0開始)
            chunk_size: 分片大小 (bytes)
        
        Returns:
            - 影片分片數據
        """
        try:
            advertisement = db.advertisements.find_one({"_id": advertisement_id})
            
            if not advertisement:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {advertisement_id} 不存在"
                }), 404
            
            video_path = advertisement.get('video_path')
            
            if not video_path or not os.path.exists(video_path):
                return jsonify({
                    "status": "error",
                    "message": "影片文件不存在"
                }), 404
            
            # 獲取參數
            chunk_number = int(request.args.get('chunk', 0))
            chunk_size = int(request.args.get('chunk_size', CHUNK_SIZE))
            
            file_size = os.path.getsize(video_path)
            total_chunks = (file_size + chunk_size - 1) // chunk_size
            
            # 檢查分片編號
            if chunk_number >= total_chunks:
                return jsonify({
                    "status": "error",
                    "message": f"分片編號超出範圍: {chunk_number} >= {total_chunks}"
                }), 400
            
            # 計算分片範圍
            start_byte = chunk_number * chunk_size
            end_byte = min(start_byte + chunk_size, file_size)
            
            # 讀取分片數據
            with open(video_path, 'rb') as f:
                f.seek(start_byte)
                chunk_data = f.read(end_byte - start_byte)
            
            from flask import Response
            
            response = Response(
                chunk_data,
                mimetype='application/octet-stream',
                headers={
                    'Content-Range': f'bytes {start_byte}-{end_byte-1}/{file_size}',
                    'Accept-Ranges': 'bytes',
                    'Content-Length': str(len(chunk_data)),
                    'X-Chunk-Number': str(chunk_number),
                    'X-Total-Chunks': str(total_chunks)
                }
            )
            
            return response
            
        except Exception as e:
            logger.error(f"下載影片分片失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "下載影片分片失敗"
            }), 500
    
    
    @admin_api.route('/videos/<advertisement_id>', methods=['DELETE'])
    def delete_video(advertisement_id):
        """
        刪除影片（包括文件和數據庫記錄）
        
        前端用途：
        - 影片管理頁面
        - 刪除不需要的影片
        
        Returns:
            {
                "status": "success",
                "message": "影片刪除成功"
            }
        """
        try:
            advertisement = db.advertisements.find_one({"_id": advertisement_id})
            
            if not advertisement:
                return jsonify({
                    "status": "error",
                    "message": f"廣告 {advertisement_id} 不存在"
                }), 404
            
            # 刪除文件
            video_path = advertisement.get('video_path')
            if video_path and os.path.exists(video_path):
                try:
                    os.remove(video_path)
                    logger.info(f"影片文件已刪除: {video_path}")
                except Exception as e:
                    logger.warning(f"刪除影片文件失敗: {e}")
            
            # 刪除數據庫記錄
            db.advertisements.delete_one({"_id": advertisement_id})
            
            # 同時刪除相關的活動
            db.campaigns.delete_many({"advertisement_id": advertisement_id})
            
            logger.info(f"影片記錄已刪除: {advertisement_id}")
            
            return jsonify({
                "status": "success",
                "message": "影片刪除成功"
            }), 200
            
        except Exception as e:
            logger.error(f"刪除影片失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "刪除影片失敗"
            }), 500
    
    
    # ========================================================================
    # 廣告選擇 API
    # ========================================================================
    
    @admin_api.route('/advertisements/available', methods=['GET'])
    def get_available_advertisements():
        """
        獲取所有可用的廣告（用於推送選擇）
        
        前端用途：
        - 推送頁面的廣告選擇器
        - 廣告下拉選單
        
        Query Parameters:
            status: 過濾狀態 (active/inactive)，默認只返回active
            with_files: 是否只返回有影片文件的廣告 (true/false)
        
        Returns:
            {
                "status": "success",
                "advertisements": [
                    {
                        "advertisement_id": "adv-001",
                        "name": "廣告名稱",
                        "video_filename": "video.mp4",
                        "file_exists": true,
                        "file_size": 12345678,
                        "duration": 30
                    }
                ]
            }
        """
        try:
            # 獲取查詢參數
            status_filter = request.args.get('status', 'active')  # 默認只返回active
            with_files_only = request.args.get('with_files', 'false').lower() == 'true'
            
            # 構建查詢條件
            query = {"status": status_filter}
            
            # 查詢廣告
            ads = list(db.advertisements.find(query))
            
            # 處理結果
            available_ads = []
            for ad in ads:
                video_path = ad.get('video_path')
                file_exists = video_path and os.path.exists(video_path) if video_path else False
                
                # 如果只要求有文件的廣告，跳過沒有文件的
                if with_files_only and not file_exists:
                    continue
                
                ad_info = {
                    "advertisement_id": ad['_id'],
                    "name": ad.get('name', ''),
                    "video_filename": ad.get('video_filename', ''),
                    "file_exists": file_exists,
                    "file_size": ad.get('file_size', 0),
                    "duration": ad.get('duration'),
                    "type": ad.get('type', 'general'),
                    "priority": ad.get('priority', 5),
                    "created_at": ad.get('created_at')
                }
                available_ads.append(ad_info)
            
            # 按優先級和創建時間排序
            available_ads.sort(key=lambda x: (-x.get('priority', 5), x.get('created_at', '')))
            
            return jsonify({
                "status": "success",
                "total": len(available_ads),
                "advertisements": available_ads
            }), 200
            
        except Exception as e:
            logger.error(f"獲取可用廣告失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取可用廣告失敗"
            }), 500
    
    
    # ========================================================================
    # 主動推送廣告下載 API
    # ========================================================================
    
    @admin_api.route('/push/download', methods=['POST'])
    def push_download_command():
        """
        主動推送廣告下載命令到設備
        
        前端用途：
        - 管理員主動推送廣告下載
        - 批量推送廣告到設備
        
        Request Body:
            {
                "target_device_ids": ["taxi-AAB-1234-rooftop"],
                "advertisement_id": "adv-002",
                "priority": "high",
                "download_mode": "chunked"  // chunked 或 normal
            }
        
        Returns:
            {
                "status": "success",
                "command": "DOWNLOAD_VIDEO",
                "advertisement": {...},
                "results": {...},
                "summary": {...}
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            target_device_ids = data.get('target_device_ids', [])
            advertisement_id = data.get('advertisement_id')
            priority = data.get('priority', 'normal')
            download_mode = data.get('download_mode', 'chunked')
            
            # 驗證必要欄位
            if not target_device_ids or not advertisement_id:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: target_device_ids 和 advertisement_id"
                }), 400
            
            if not isinstance(target_device_ids, list):
                return jsonify({
                    "status": "error",
                    "message": "target_device_ids 必須是陣列"
                }), 400
            
            logger.info(f"收到推送下載請求 - 目標設備: {target_device_ids}, 廣告: {advertisement_id}, 模式: {download_mode}")
            
            # 查找廣告信息
            advertisement = db.advertisements.find_one({"_id": advertisement_id})
            
            if not advertisement:
                return jsonify({
                    "status": "error",
                    "message": f"找不到廣告: {advertisement_id}"
                }), 404
            
            video_path = advertisement.get('video_path')
            video_filename = advertisement.get('video_filename')
            
            if not video_path or not os.path.exists(video_path):
                return jsonify({
                    "status": "error",
                    "message": "影片文件不存在"
                }), 404
            
            # 獲取文件信息
            file_size = os.path.getsize(video_path)
            chunk_size = CHUNK_SIZE
            total_chunks = (file_size + chunk_size - 1) // chunk_size
            
            # 構建下載命令載荷
            download_command = {
                "command": "DOWNLOAD_VIDEO",
                "advertisement_id": advertisement_id,
                "advertisement_name": advertisement.get('name', ''),
                "video_filename": video_filename,
                "file_size": file_size,
                "download_mode": download_mode,
                "priority": priority,
                "trigger": "admin_push",
                "timestamp": datetime.now().isoformat()
            }
            
            # 如果是分片下載模式，添加分片信息
            if download_mode == 'chunked':
                download_command.update({
                    "chunk_size": chunk_size,
                    "total_chunks": total_chunks,
                    "download_url": f"/api/v1/device/videos/{advertisement_id}/chunk",
                    "download_info_url": f"/api/v1/device/videos/{advertisement_id}/download"
                })
            else:
                download_command.update({
                    "download_url": f"/api/v1/device/videos/{advertisement_id}/download"
                })
            
            # 向每個目標設備推送下載命令
            sent_to = []
            offline_devices = []
            
            for device_id in target_device_ids:
                sid = device_to_sid.get(device_id)
                
                if sid:
                    try:
                        # 發送下載命令到特定客戶端
                        socketio.emit('download_video', download_command, room=sid)
                        sent_to.append(device_id)
                        connection_stats['messages_sent'] += 1
                        logger.info(f"下載命令已發送到: {device_id} (SID: {sid})")
                    except Exception as e:
                        logger.error(f"發送到 {device_id} 時出錯: {e}")
                        offline_devices.append(device_id)
                else:
                    offline_devices.append(device_id)
                    logger.warning(f"設備離線或未連接: {device_id}")
            
            # 構建並返回響應
            response = {
                "status": "success",
                "command": "DOWNLOAD_VIDEO",
                "advertisement": {
                    "id": advertisement_id,
                    "name": advertisement.get('name', ''),
                    "video_filename": video_filename,
                    "file_size": file_size,
                    "download_mode": download_mode
                },
                "results": {
                    "sent": sent_to,
                    "offline": offline_devices
                },
                "summary": {
                    "total_targets": len(target_device_ids),
                    "sent_count": len(sent_to),
                    "offline_count": len(offline_devices)
                },
                "download_info": {
                    "chunk_size": chunk_size if download_mode == 'chunked' else None,
                    "total_chunks": total_chunks if download_mode == 'chunked' else None
                },
                "timestamp": datetime.now().isoformat()
            }
            
            return jsonify(response), 200
            
        except Exception as e:
            logger.error(f"處理推送下載請求時出錯: {e}", exc_info=True)
            return jsonify({
                "status": "error",
                "message": "內部伺服器錯誤",
                "detail": str(e)
            }), 500
    
    
    @admin_api.route('/push/batch', methods=['POST'])
    def batch_push_download():
        """
        批量推送多個廣告下載命令
        
        前端用途：
        - 批量推送多個廣告到設備
        - 設備更新廣告庫
        
        Request Body:
            {
                "target_device_ids": ["taxi-AAB-1234-rooftop"],
                "advertisement_ids": ["adv-001", "adv-002"],
                "priority": "high",
                "download_mode": "chunked"
            }
        
        Returns:
            {
                "status": "success",
                "results": {...},
                "summary": {...}
            }
        """
        try:
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            target_device_ids = data.get('target_device_ids', [])
            advertisement_ids = data.get('advertisement_ids', [])
            priority = data.get('priority', 'normal')
            download_mode = data.get('download_mode', 'chunked')
            
            # 驗證必要欄位
            if not target_device_ids or not advertisement_ids:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: target_device_ids 和 advertisement_ids"
                }), 400
            
            logger.info(f"收到批量推送請求 - 目標設備: {target_device_ids}, 廣告: {advertisement_ids}")
            
            batch_results = []
            total_sent = 0
            total_failed = 0
            
            # 對每個廣告執行推送
            for advertisement_id in advertisement_ids:
                # 查找廣告信息
                advertisement = db.advertisements.find_one({"_id": advertisement_id})
                
                if not advertisement:
                    batch_results.append({
                        "advertisement_id": advertisement_id,
                        "status": "error",
                        "message": "廣告不存在"
                    })
                    total_failed += 1
                    continue
                
                video_path = advertisement.get('video_path')
                
                if not video_path or not os.path.exists(video_path):
                    batch_results.append({
                        "advertisement_id": advertisement_id,
                        "status": "error",
                        "message": "影片文件不存在"
                    })
                    total_failed += 1
                    continue
                
                # 獲取文件信息
                file_size = os.path.getsize(video_path)
                chunk_size = CHUNK_SIZE
                total_chunks = (file_size + chunk_size - 1) // chunk_size
                
                # 構建下載命令
                download_command = {
                    "command": "DOWNLOAD_VIDEO",
                    "advertisement_id": advertisement_id,
                    "advertisement_name": advertisement.get('name', ''),
                    "video_filename": advertisement.get('video_filename', ''),
                    "file_size": file_size,
                    "download_mode": download_mode,
                    "priority": priority,
                    "trigger": "batch_push",
                    "batch_id": str(uuid.uuid4()),
                    "timestamp": datetime.now().isoformat()
                }
                
                if download_mode == 'chunked':
                    download_command.update({
                        "chunk_size": chunk_size,
                        "total_chunks": total_chunks,
                        "download_url": f"/api/v1/device/videos/{advertisement_id}/chunk",
                        "download_info_url": f"/api/v1/device/videos/{advertisement_id}/download"
                    })
                else:
                    download_command.update({
                        "download_url": f"/api/v1/device/videos/{advertisement_id}/download"
                    })
                
                # 推送到所有目標設備
                sent_to = []
                offline_devices = []
                
                for device_id in target_device_ids:
                    sid = device_to_sid.get(device_id)
                    
                    if sid:
                        try:
                            socketio.emit('download_video', download_command, room=sid)
                            sent_to.append(device_id)
                            connection_stats['messages_sent'] += 1
                        except Exception as e:
                            logger.error(f"發送到 {device_id} 時出錯: {e}")
                            offline_devices.append(device_id)
                    else:
                        offline_devices.append(device_id)
                
                batch_results.append({
                    "advertisement_id": advertisement_id,
                    "status": "success",
                    "sent_to": sent_to,
                    "offline_devices": offline_devices,
                    "file_size": file_size,
                    "total_chunks": total_chunks if download_mode == 'chunked' else None
                })
                
                total_sent += len(sent_to)
                total_failed += len(offline_devices)
            
            # 構建響應
            response = {
                "status": "success",
                "batch_results": batch_results,
                "summary": {
                    "total_advertisements": len(advertisement_ids),
                    "total_devices": len(target_device_ids),
                    "total_sent": total_sent,
                    "total_failed": total_failed,
                    "download_mode": download_mode
                },
                "timestamp": datetime.now().isoformat()
            }
            
            return jsonify(response), 200
            
        except Exception as e:
            logger.error(f"處理批量推送請求時出錯: {e}", exc_info=True)
            return jsonify({
                "status": "error",
                "message": "內部伺服器錯誤",
                "detail": str(e)
            }), 500
    
    
    # ========================================================================
    # 推送控制 API（已存在，但在這裡列出供參考）
    # ========================================================================
    
    @admin_api.route('/override', methods=['POST'])
    def admin_override():
        """
        管理員推送覆蓋命令
        
        前端用途：
        - 即時推送頁面
        - 批量推送功能
        
        Request Body:
            {
                "target_device_ids": ["taxi-AAB-1234-rooftop"],
                "advertisement_id": "adv-002"
            }
        
        Returns:
            {
                "status": "success",
                "advertisement": {...},
                "results": {...},
                "summary": {...}
            }
        """
        try:
            # 解析請求數據
            data = request.get_json()
            
            if not data:
                return jsonify({
                    "status": "error",
                    "message": "請求體不能為空"
                }), 400
            
            target_device_ids = data.get('target_device_ids', [])
            advertisement_id = data.get('advertisement_id')
            
            # 驗證必要欄位
            if not target_device_ids or not advertisement_id:
                return jsonify({
                    "status": "error",
                    "message": "缺少必要欄位: target_device_ids 和 advertisement_id"
                }), 400
            
            if not isinstance(target_device_ids, list):
                return jsonify({
                    "status": "error",
                    "message": "target_device_ids 必須是陣列"
                }), 400
            
            logger.info(f"收到管理員推送請求 - 目標設備: {target_device_ids}, 廣告: {advertisement_id}")
            
            # 查找廣告信息
            advertisement = db.advertisements.find_one({"_id": advertisement_id})
            
            if not advertisement:
                return jsonify({
                    "status": "error",
                    "message": f"找不到廣告: {advertisement_id}"
                }), 404
            
            video_filename = advertisement.get('video_filename')
            
            if not video_filename:
                return jsonify({
                    "status": "error",
                    "message": "廣告缺少 video_filename 欄位"
                }), 500
            
            # 構建推送載荷
            payload = {
                "command": "PLAY_VIDEO",
                "video_filename": video_filename,
                "advertisement_id": advertisement_id,
                "advertisement_name": advertisement.get('name', ''),
                "trigger": "admin_override",
                "priority": "override",
                "timestamp": datetime.now().isoformat()
            }
            
            # 向每個目標設備推送命令
            sent_to = []
            offline_devices = []
            
            for device_id in target_device_ids:
                sid = device_to_sid.get(device_id)
                
                if sid:
                    try:
                        # 發送覆蓋命令到特定客戶端
                        socketio.emit('play_ad', payload, room=sid)
                        sent_to.append(device_id)
                        connection_stats['messages_sent'] += 1
                        if device_playback_state is not None:
                            device_playback_state[device_id] = {
                                "mode": "override_play",
                                "video_filename": video_filename,
                                "advertisement_id": advertisement_id,
                                "advertisement_name": advertisement.get('name', ''),
                                "campaign_id": None,
                                "playlist": [],
                                "updated_at": datetime.now().isoformat()
                            }
                        logger.info(f"推送命令已發送到: {device_id} (SID: {sid})")
                    except Exception as e:
                        logger.error(f"發送到 {device_id} 時出錯: {e}")
                        offline_devices.append(device_id)
                else:
                    offline_devices.append(device_id)
                    logger.warning(f"設備離線或未連接: {device_id}")
            
            # 構建並返回響應
            response = {
                "status": "success",
                "advertisement": {
                    "id": advertisement_id,
                    "name": advertisement.get('name', ''),
                    "video_filename": video_filename,
                    "type": advertisement.get('type', '')
                },
                "results": {
                    "sent": sent_to,
                    "offline": offline_devices
                },
                "summary": {
                    "total_targets": len(target_device_ids),
                    "sent_count": len(sent_to),
                    "offline_count": len(offline_devices)
                },
                "timestamp": datetime.now().isoformat()
            }
            
            return jsonify(response), 200
            
        except Exception as e:
            logger.error(f"處理管理員推送請求時出錯: {e}", exc_info=True)
            return jsonify({
                "status": "error",
                "message": "內部伺服器錯誤",
                "detail": str(e)
            }), 500
    
    
    # ========================================================================
    # 統計數據 API
    # ========================================================================
    
    @admin_api.route('/stats/overview', methods=['GET'])
    def get_stats_overview():
        """
        獲取統計總覽
        
        前端用途：
        - 儀表板統計卡片
        - 數據總覽
        
        Returns:
            {
                "status": "success",
                "stats": {...}
            }
        """
        try:
            # 獲取設備總數
            total_devices = db.devices.count_documents({})
            
            # 獲取廣告總數
            total_ads = db.advertisements.count_documents({})
            active_ads = db.advertisements.count_documents({"status": "active"})
            
            # 獲取活動總數
            total_campaigns = db.campaigns.count_documents({})
            active_campaigns = db.campaigns.count_documents({"status": "active"})
            
            stats = {
                "devices": {
                    "total": total_devices,
                    "online": connection_stats['active_devices'],
                    "offline": total_devices - connection_stats['active_devices']
                },
                "advertisements": {
                    "total": total_ads,
                    "active": active_ads,
                    "inactive": total_ads - active_ads
                },
                "campaigns": {
                    "total": total_campaigns,
                    "active": active_campaigns,
                    "inactive": total_campaigns - active_campaigns
                },
                "connections": connection_stats
            }
            
            return jsonify({
                "status": "success",
                "stats": stats
            }), 200
            
        except Exception as e:
            logger.error(f"獲取統計數據失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "獲取統計數據失敗"
            }), 500
    
    
    # ========================================================================
    # QR Code 掃描事件 API
    # ========================================================================
    
    @admin_api.route('/qr-scan', methods=['POST'])
    def record_qr_scan():
        """
        記錄使用者掃描 QR Code 事件
        
        前端用途：
        - QR Code 掃描頁面載入時自動調用
        - 通知管理員系統有使用者掃描了 QR Code
        
        Request Body:
            {
                "timestamp": "2025-01-01T12:00:00",
                "user_agent": "Mozilla/5.0...",
                "referrer": "https://example.com",
                "screen_width": 1920,
                "screen_height": 1080
            }
        
        Returns:
            {
                "status": "success",
                "message": "QR Code 掃描事件已記錄",
                "scan_id": "..."
            }
        """
        try:
            data = request.get_json() or {}
            
            # 獲取客戶端 IP
            client_ip = request.remote_addr
            if request.headers.get('X-Forwarded-For'):
                client_ip = request.headers.get('X-Forwarded-For').split(',')[0].strip()
            
            # 構建掃描記錄
            scan_record = {
                "scan_id": str(uuid.uuid4()),
                "timestamp": data.get('timestamp', datetime.now().isoformat()),
                "client_ip": client_ip,
                "user_agent": data.get('user_agent', request.headers.get('User-Agent', 'Unknown')),
                "referrer": data.get('referrer', request.headers.get('Referer', 'direct')),
                "screen_width": data.get('screen_width'),
                "screen_height": data.get('screen_height'),
                "created_at": datetime.now().isoformat()
            }
            
            # 記錄到日誌
            logger.info(f"📱 [QR Code 掃描] 使用者掃描QRcode - IP: {client_ip}, 時間: {scan_record['timestamp']}")
            
            # 可以選擇將記錄保存到數據庫（如果需要的話）
            # 這裡我們先記錄到日誌，如果需要持久化，可以創建一個 qr_scans 集合
            # if hasattr(db, 'qr_scans'):
            #     db.qr_scans.insert_one(scan_record)
            
            # 通過 WebSocket 廣播給所有管理員（如果有的話）
            try:
                socketio.emit('qr_scan_event', {
                    "type": "qr_scan",
                    "message": "使用者掃描QRcode",
                    "data": scan_record,
                    "timestamp": datetime.now().isoformat()
                }, namespace='/')
                logger.debug("已通過 WebSocket 廣播 QR Code 掃描事件")
            except Exception as ws_error:
                logger.warning(f"WebSocket 廣播失敗: {ws_error}")
            
            return jsonify({
                "status": "success",
                "message": "QR Code 掃描事件已記錄",
                "scan_id": scan_record['scan_id'],
                "timestamp": scan_record['timestamp']
            }), 200
            
        except Exception as e:
            logger.error(f"記錄 QR Code 掃描事件失敗: {e}")
            return jsonify({
                "status": "error",
                "message": "記錄掃描事件失敗"
            }), 500
    
    
    return admin_api

