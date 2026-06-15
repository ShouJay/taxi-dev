"""
智能計程車廣告服務 - 整合版
結合廣告決策和實時推送功能

功能特點：
1. 設備定期發送位置數據
2. 服務器進行廣告決策
3. 通過 WebSocket 實時推送廣告
4. 支持管理員主動插播
"""

from flask import Flask, request, jsonify, Response, redirect
from flask_socketio import SocketIO, emit, disconnect
from flask_cors import CORS
import logging
from datetime import datetime
import os

# 導入配置和模組
from src.config import FLASK_HOST, FLASK_PORT, FLASK_DEBUG, LOG_LEVEL, MONGODB_URI, DATABASE_NAME
from src.database import Database
from src.services import AdDecisionService
from src.models import HeartbeatRequest, HeartbeatResponse
from src.sample_data import SampleData
from src.admin_api import init_admin_api
from src.dual_screen_api import dual_screen_bp
from src.emergency_manager import EmergencyManager

# ============================================================================
# 應用程序設置
# ============================================================================

print("!!!!!!!!!👉 現在的 MONGODB_URI =", MONGODB_URI)


app = Flask(__name__)
app.config['SECRET_KEY'] = 'your-secret-key-change-in-production'
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024 * 1024  # 10GB 限制
CORS(app)

# 初始化 SocketIO
socketio = SocketIO(
    app,
    cors_allowed_origins="*",  # 生產環境應限制來源
    async_mode='eventlet'
)

# 初始化緊急管理器並注入 SocketIO
emergency_manager = EmergencyManager()
emergency_manager.set_socketio(socketio)

# 設置日誌
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# ============================================================================
# 數據庫和服務初始化
# ============================================================================

try:
    # 初始化數據庫連接
    db = Database(MONGODB_URI, DATABASE_NAME)
    
    # 初始化廣告決策服務
    ad_service = AdDecisionService(db)
    
    logger.info("整合應用程序初始化完成")
except Exception as e:
    logger.error(f"應用程序初始化失敗: {e}")
    raise

# ============================================================================
# WebSocket 連接管理
# ============================================================================

# 映射: session_id (sid) -> device_id
active_connections = {}

# 映射: device_id -> session_id (sid) - 用於快速查找
device_to_sid = {}

# 連接統計
connection_stats = {
    "total_connections": 0,
    "active_devices": 0,
    "messages_sent": 0,
    "location_updates": 0
}

# 設備 -> 當前活動狀態快取
device_campaign_state = {}

# 設備 -> 當前播放狀態快取
device_playback_state = {}


def get_active_devices():
    """獲取所有活動設備列表"""
    return list(device_to_sid.keys())


def get_device_sid(device_id):
    """根據設備 ID 獲取 session ID"""
    return device_to_sid.get(device_id)


def register_device(sid, device_id):
    """註冊設備連接"""
    # 如果設備已經有連接，先移除舊連接
    if device_id in device_to_sid:
        old_sid = device_to_sid[device_id]
        if old_sid in active_connections:
            del active_connections[old_sid]
            logger.warning(f"設備 {device_id} 的舊連接 {old_sid} 已被替換")
    
    # 註冊新連接
    active_connections[sid] = {
        'device_id': device_id,
        'connected_at': datetime.now().isoformat(),
        'last_activity': datetime.now().isoformat()
    }
    device_to_sid[device_id] = sid
    connection_stats['active_devices'] = len(device_to_sid)
    
    logger.info(f"設備已註冊: {device_id} (SID: {sid})")

    device_playback_state[device_id] = {
        "mode": "registered",
        "video_filename": None,
        "advertisement_id": None,
        "advertisement_name": None,
        "campaign_id": None,
        "playlist": [],
        "updated_at": datetime.now().isoformat()
    }


def unregister_device(sid):
    """取消註冊設備連接"""
    if sid in active_connections:
        device_id = active_connections[sid]['device_id']
        del active_connections[sid]
        
        if device_id in device_to_sid:
            del device_to_sid[device_id]
        
        connection_stats['active_devices'] = len(device_to_sid)
        logger.info(f"設備已斷開: {device_id} (SID: {sid})")
        device_playback_state[device_id] = {
            "mode": "offline",
            "video_filename": None,
            "advertisement_id": None,
            "advertisement_name": None,
            "campaign_id": None,
            "playlist": [],
            "updated_at": datetime.now().isoformat()
        }
        return device_id
    return None


# ============================================================================
# WebSocket 事件處理
# ============================================================================

@socketio.on('connect')
def handle_connect():
    """處理客戶端連接事件"""
    sid = request.sid
    connection_stats['total_connections'] += 1
    
    logger.info(f"新的 WebSocket 連接: SID={sid}")
    
    # 發送歡迎消息
    emit('connection_established', {
        'message': '連接成功！請發送 register 事件註冊您的設備',
        'sid': sid,
        'timestamp': datetime.now().isoformat()
    })


@socketio.on('register')
def handle_register(data):
    """處理設備註冊事件"""
    sid = request.sid
    
    try:
        device_id = data.get('device_id')
        
        if not device_id:
            emit('registration_error', {
                'error': '缺少 device_id 參數'
            })
            logger.warning(f"註冊失敗: 缺少 device_id (SID: {sid})")
            return
        
        # 驗證設備是否存在於數據庫
        device = db.devices.find_one({"_id": device_id})
        
        if not device:
            emit('registration_error', {
                'error': f'設備 {device_id} 不存在於系統中'
            })
            logger.warning(f"註冊失敗: 設備不存在 {device_id} (SID: {sid})")
            return
        
        # 註冊設備
        register_device(sid, device_id)
        
        # 發送註冊成功確認
        emit('registration_success', {
            'message': f'設備 {device_id} 註冊成功',
            'device_id': device_id,
            'device_type': device.get('device_type'),
            'timestamp': datetime.now().isoformat()
        })
        
        # [V2] 自動推送當前的雙螢幕系統狀態與統計數據
        # 這樣 App 一連上並註冊後，就能立即知道當前的跑馬燈、警報狀態與 QR 計數
        current_state = emergency_manager.get_state()
        emit('system_state_update', current_state)
        emit('stats_update', {
            "qr_scan_count": emergency_manager.qr_scan_count,
            "timestamp": datetime.now().isoformat()
        })
        
        logger.info(f"設備註冊成功: {device_id} (SID: {sid})")
        
    except Exception as e:
        logger.error(f"處理註冊事件時出錯: {e}")
        emit('registration_error', {
            'error': '內部伺服器錯誤'
        })


@socketio.on('location_update')
def handle_location_update(data):
    """
    處理設備位置更新事件 - 核心功能！
    
    設備發送位置數據，服務器進行廣告決策並實時推送
    """
    sid = request.sid
    
    try:
        device_id = data.get('device_id')
        longitude = data.get('longitude')
        latitude = data.get('latitude')
        
        # 驗證數據
        if not device_id or longitude is None or latitude is None:
            emit('location_error', {
                'error': '缺少必要欄位: device_id, longitude, latitude'
            })
            return
        
        # 驗證經緯度範圍
        if not (-180 <= longitude <= 180) or not (-90 <= latitude <= 90):
            emit('location_error', {
                'error': '經緯度範圍無效'
            })
            return
        
        # 檢查設備是否已註冊
        if sid not in active_connections:
            emit('location_error', {
                'error': '設備未註冊，請先發送 register 事件'
            })
            return
        
        logger.info(f"收到位置更新: {device_id} -> ({longitude}, {latitude})")
        
        # 執行廣告決策
        ad_info = ad_service.decide_ad(device_id, longitude, latitude)
        matching_campaign_id = ad_info.get('campaign_id') if ad_info else None
        current_campaign_id = device_campaign_state.get(device_id)

        connection_stats['location_updates'] += 1

        if matching_campaign_id == current_campaign_id:
            logger.info(f"[狀態不變] {device_id} 仍在 {current_campaign_id}。不推送。")
            if device_id in device_playback_state:
                device_playback_state[device_id]["updated_at"] = datetime.now().isoformat()
            emit('location_ack', {
                'message': '位置更新已處理，狀態未改變',
                'campaign_id': current_campaign_id,
                'timestamp': datetime.now().isoformat()
            })
            return

        logger.warning(f"[狀態改變] {device_id}: {current_campaign_id} -> {matching_campaign_id}")
        device_campaign_state[device_id] = matching_campaign_id

        if matching_campaign_id is not None and ad_info:
            advertisement_ids = ad_info.get('advertisement_ids', [])
            campaign_playlist = []

            for ad_id in advertisement_ids:
                advertisement = db.advertisements.find_one({"_id": ad_id})
                if advertisement:
                    campaign_playlist.append({
                        "videoFilename": advertisement.get('video_filename'),
                        "advertisementId": ad_id,
                        "advertisementName": advertisement.get('name')
                    })
                else:
                    logger.warning(f"未找到廣告 {ad_id}，無法加入播放列表")

            logger.info(f"推送 [START_CAMPAIGN] 到 {device_id} (活動: {matching_campaign_id})")

            emit('start_campaign_playback', {
                "command": "START_CAMPAIGN_PLAYBACK",
                "campaign_id": matching_campaign_id,
                "playlist": campaign_playlist,
                "timestamp": datetime.now().isoformat()
            })
            connection_stats['messages_sent'] += 1

            first_entry = campaign_playlist[0] if campaign_playlist else {}
            device_playback_state[device_id] = {
                "mode": "campaign_playback",
                "video_filename": first_entry.get("videoFilename"),
                "advertisement_id": first_entry.get("advertisementId"),
                "advertisement_name": first_entry.get("advertisementName"),
                "campaign_id": matching_campaign_id,
                "playlist": campaign_playlist,
                "updated_at": datetime.now().isoformat()
            }

            emit('location_ack', {
                'message': '位置更新已處理，活動已開始',
                'campaign_id': matching_campaign_id,
                'playlist_size': len(campaign_playlist),
                'timestamp': datetime.now().isoformat()
            })
        else:
            logger.info(f"推送 [REVERT_TO_LOCAL] 到 {device_id}")
            emit('revert_to_local_playlist', {
                "command": "REVERT_TO_LOCAL_PLAYLIST",
                "timestamp": datetime.now().isoformat()
            })
            connection_stats['messages_sent'] += 1

            device_playback_state[device_id] = {
                "mode": "local_playlist",
                "video_filename": None,
                "advertisement_id": None,
                "advertisement_name": None,
                "campaign_id": None,
                "playlist": [],
                "updated_at": datetime.now().isoformat()
            }

            emit('location_ack', {
                'message': '位置更新已處理，恢復為本地播放列表',
                'campaign_id': None,
                'timestamp': datetime.now().isoformat()
            })
        
    except Exception as e:
        logger.error(f"處理位置更新時出錯: {e}")
        emit('location_error', {
            'error': '處理位置更新時發生錯誤'
        })


@socketio.on('playback_error')
def handle_playback_error(data):
    """處理前端回報的播放錯誤"""
    sid = request.sid
    device_id = active_connections.get(sid, {}).get('device_id', 'Unknown')

    error_msg = data.get('error', 'Unknown error')
    campaign_id = data.get('campaign_id')
    video_filename = data.get('video_filename')

    logger.error(f"🚨 [前端播放錯誤] 設備: {device_id}")
    logger.error(f"   活動: {campaign_id}, 影片: {video_filename}")
    logger.error(f"   錯誤訊息: {error_msg}")

    emit('error_ack', {'message': '錯誤已收到'})


@socketio.on('disconnect')
def handle_disconnect():
    """處理客戶端斷開連接事件"""
    sid = request.sid
    device_id = unregister_device(sid)
    
    if device_id:
        logger.info(f"設備斷開連接: {device_id} (SID: {sid})")
    else:
        logger.info(f"未註冊的連接斷開: SID={sid}")


@socketio.on('heartbeat')
def handle_heartbeat(data):
    """處理設備心跳事件"""
    sid = request.sid
    
    if sid in active_connections:
        active_connections[sid]['last_activity'] = datetime.now().isoformat()
        device_id = active_connections[sid]['device_id']
        
        emit('heartbeat_ack', {
            'device_id': device_id,
            'timestamp': datetime.now().isoformat()
        })
        
        logger.debug(f"收到心跳: {device_id}")


@socketio.on('download_status')
def handle_download_status(data):
    """
    處理設備下載狀態回報
    
    設備發送下載進度和狀態信息
    """
    sid = request.sid
    
    try:
        device_id = data.get('device_id')
        advertisement_id = data.get('advertisement_id')
        status = data.get('status')  # downloading, completed, failed, paused
        progress = data.get('progress', 0)  # 0-100
        downloaded_chunks = data.get('downloaded_chunks', [])
        total_chunks = data.get('total_chunks', 0)
        error_message = data.get('error_message')
        
        # 驗證數據
        if not device_id or not advertisement_id or not status:
            emit('download_status_error', {
                'error': '缺少必要欄位: device_id, advertisement_id, status'
            })
            return
        
        # 檢查設備是否已註冊
        if sid not in active_connections:
            emit('download_status_error', {
                'error': '設備未註冊，請先發送 register 事件'
            })
            return
        
        logger.info(f"收到下載狀態: {device_id} -> {advertisement_id}, 狀態: {status}, 進度: {progress}%")
        
        # 發送確認消息
        emit('download_status_ack', {
            'message': '下載狀態已收到',
            'advertisement_id': advertisement_id,
            'status': status,
            'progress': progress,
            'timestamp': datetime.now().isoformat()
        })
        
        if status == 'completed':
            logger.info(f"設備 {device_id} 完成下載廣告 {advertisement_id}")
        
    except Exception as e:
        logger.error(f"處理下載狀態時出錯: {e}")
        emit('download_status_error', {
            'error': '處理下載狀態時發生錯誤'
        })


@socketio.on('download_request')
def handle_download_request(data):
    """
    處理設備主動請求下載廣告 - 強制分片模式
    
    設備可以主動請求下載特定廣告
    """
    sid = request.sid
    
    try:
        device_id = data.get('device_id')
        advertisement_id = data.get('advertisement_id')
        
        # 驗證數據
        if not device_id or not advertisement_id:
            emit('download_request_error', {
                'error': '缺少必要欄位: device_id, advertisement_id'
            })
            return
        
        # 檢查設備是否已註冊
        if sid not in active_connections:
            emit('download_request_error', {
                'error': '設備未註冊，請先發送 register 事件'
            })
            return
        
        logger.info(f"收到下載請求: {device_id} -> {advertisement_id}")
        
        # 查找廣告信息
        advertisement = db.advertisements.find_one({"_id": advertisement_id})
        
        if not advertisement:
            emit('download_request_error', {
                'error': f'廣告 {advertisement_id} 不存在'
            })
            return
        
        video_path = advertisement.get('video_path')
        
        if not video_path or not os.path.exists(video_path):
            emit('download_request_error', {
                'error': '影片文件不存在'
            })
            return
        
        # 獲取文件信息 - 強制分片模式
        file_size = os.path.getsize(video_path)
        chunk_size = 10 * 1024 * 1024  # 10MB
        total_chunks = max(1, (file_size + chunk_size - 1) // chunk_size)  # 至少1個分片
        
        # 構建下載命令 - 強制分片模式
        download_command = {
            "command": "DOWNLOAD_VIDEO",
            "advertisement_id": advertisement_id,
            "advertisement_name": advertisement.get('name', ''),
            "video_filename": advertisement.get('video_filename', ''),
            "file_size": file_size,
            "download_mode": "chunked",  # 強制分片
            "priority": "normal",
            "trigger": "device_request",
            "chunk_size": chunk_size,
            "total_chunks": total_chunks,
            "download_url": f"/api/v1/device/videos/{advertisement_id}/chunk",
            "download_info_url": f"/api/v1/device/videos/{advertisement_id}/download",
            "timestamp": datetime.now().isoformat()
        }
        
        # 發送下載命令
        emit('download_video', download_command)
        
        logger.info(f"已發送下載命令到 {device_id}: {advertisement_id} (分片模式: {total_chunks} 個分片)")
        
    except Exception as e:
        logger.error(f"處理下載請求時出錯: {e}")
        emit('download_request_error', {
            'error': '處理下載請求時發生錯誤'
        })


# ============================================================================
# 設備端分片下載 API（強制分片模式）
# ============================================================================

@app.route('/api/v1/device/videos/<advertisement_id>/download', methods=['GET'])
def device_download_video_info(advertisement_id):
    """
    設備端獲取影片下載信息 - 強制分片模式
    
    設備用途：
    - 獲取影片下載信息
    - 檢查文件是否存在
    
    Query Parameters:
        chunk_size: 分片大小 (bytes)，默認 10MB
    
    Returns:
        {
            "status": "success",
            "download_info": {
                "advertisement_id": "adv-001",
                "filename": "video.mp4",
                "file_size": 12345678,
                "chunk_size": 10485760,
                "total_chunks": 3,
                "download_url": "/api/v1/device/videos/adv-001/chunk",
                "download_mode": "chunked"
            }
        }
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
        
        # 強制使用分片下載，默認 10MB 分片
        chunk_size = int(request.args.get('chunk_size', 10 * 1024 * 1024))  # 10MB
        
        # 限制分片大小範圍
        if chunk_size < 1024 * 1024:  # 最小 1MB
            chunk_size = 1024 * 1024
        elif chunk_size > 50 * 1024 * 1024:  # 最大 50MB
            chunk_size = 50 * 1024 * 1024
        
        file_size = os.path.getsize(video_path)
        
        # 即使文件小於一個分片，也至少返回 1 個分片
        total_chunks = max(1, (file_size + chunk_size - 1) // chunk_size)
        
        return jsonify({
            "status": "success",
            "download_info": {
                "advertisement_id": advertisement_id,
                "filename": advertisement.get('video_filename', 'video.mp4'),
                "file_size": file_size,
                "chunk_size": chunk_size,
                "total_chunks": total_chunks,
                "download_url": f"/api/v1/device/videos/{advertisement_id}/chunk",
                "download_mode": "chunked"  # 明確標示為分片模式
            }
        }), 200
        
    except Exception as e:
        logger.error(f"設備下載影片信息失敗: {e}")
        return jsonify({
            "status": "error",
            "message": "獲取下載信息失敗"
        }), 500


@app.route('/api/v1/device/videos/<advertisement_id>/chunk', methods=['GET'])
def device_download_video_chunk(advertisement_id):
    """
    設備端下載影片分片 - 支援小於一個分片的檔案
    
    設備用途：
    - 分片下載影片
    - 支持斷點續傳
    - 處理小檔案（小於一個chunk）
    
    Query Parameters:
        chunk: 分片編號 (從0開始)
        chunk_size: 分片大小 (bytes)，默認 10MB
    
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
        
        # 獲取與驗證參數
        chunk_param = request.args.get('chunk', '0')
        chunk_size_param = request.args.get('chunk_size', str(10 * 1024 * 1024))  # 10MB

        # 驗證 chunk
        try:
            chunk_number = int(chunk_param)
        except (TypeError, ValueError):
            return jsonify({
                "status": "error",
                "message": "參數 chunk 必須為整數"
            }), 400
        if chunk_number < 0:
            return jsonify({
                "status": "error",
                "message": "參數 chunk 不能為負數"
            }), 400

        # 驗證 chunk_size
        try:
            chunk_size = int(chunk_size_param)
        except (TypeError, ValueError):
            return jsonify({
                "status": "error",
                "message": "參數 chunk_size 必須為整數"
            }), 400
        if chunk_size <= 0:
            return jsonify({
                "status": "error",
                "message": "參數 chunk_size 必須大於 0"
            }), 400
        
        # 限制分片大小範圍
        if chunk_size < 1024 * 1024:  # 最小 1MB
            chunk_size = 1024 * 1024
        elif chunk_size > 50 * 1024 * 1024:  # 最大 50MB
            chunk_size = 50 * 1024 * 1024
        
        file_size = os.path.getsize(video_path)
        total_chunks = max(1, (file_size + chunk_size - 1) // chunk_size)  # 至少1個分片
        
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
        
        response = Response(
            chunk_data,
            mimetype='application/octet-stream',
            headers={
                'Content-Range': f'bytes {start_byte}-{end_byte-1}/{file_size}',
                'Accept-Ranges': 'bytes',
                'Content-Length': str(len(chunk_data)),
                'X-Chunk-Number': str(chunk_number),
                'X-Total-Chunks': str(total_chunks),
                'X-Advertisement-ID': advertisement_id,
                'X-File-Size': str(file_size)
            }
        )
        
        logger.info(f"設備下載分片: {advertisement_id}, 分片 {chunk_number}/{total_chunks}, 大小: {len(chunk_data)} bytes")
        
        return response
        
    except Exception as e:
        logger.error(f"設備下載影片分片失敗: {e}")
        return jsonify({
            "status": "error",
            "message": "下載影片分片失敗"
        }), 500


# ============================================================================
# HTTP API 端點
# ============================================================================

@app.route('/')
@app.route('/home')
def index():
    """根路徑 - 重定向到管理介面"""
    return """
    <html>
    <head>
        <title>智能計程車廣告系統</title>
        <meta charset="utf-8">
        <script>window.location.href='/admin';</script>
    </head>
    <body>
        <h1>智能計程車廣告系統</h1>
        <p>正在重定向到管理介面...</p>
        <p>如果沒有自動跳轉，請<a href="/admin">點擊這裡</a></p>
    </body>
    </html>
    """


@app.route('/health', methods=['GET'])
def health_check():
    """健康檢查端點"""
    try:
        is_healthy = db.health_check()
        
        if is_healthy:
            return jsonify({
                "status": "healthy",
                "database": "connected",
                "active_connections": connection_stats['active_devices'],
                "total_connections": connection_stats['total_connections'],
                "messages_sent": connection_stats['messages_sent'],
                "location_updates": connection_stats['location_updates']
            }), 200
        else:
            return jsonify({
                "status": "unhealthy",
                "database": "disconnected"
            }), 503
    except Exception as e:
        return jsonify({
            "status": "unhealthy",
            "database": "disconnected",
            "error": str(e)
        }), 503

### 1/16

# ============================================================================
# QR Code 多地點轉址與統計系統
# ============================================================================

# 定義地點與目標網址的對照表
QR_LOCATIONS = {
    "shibuya": {
        "name": "涉谷十字路",
        "url": "https://www.shibuya-scramble-square.com.t.apy.hp.transer.com/"
    },
    "tokyo_tower": {
        "name": "東京鐵塔",
        "url": "https://zh.tokyotower.co.jp/"
    },
    "tokyo_station": {
        "name": "東京車站一番街",
        "url": "https://www.tokyoeki-1bangai.co.jp/"
    }
}

@app.route('/qr/<location_key>')
def qr_redirect(location_key):
    """
    通用 QR Code 轉址入口
    路徑範例: /qr/shibuya, /qr/tokyo_tower
    """
    # 1. 檢查地點是否有效
    target = QR_LOCATIONS.get(location_key)
    
    # 如果是無效的地點，導回首頁或顯示錯誤
    if not target:
        return f"無效的 QR Code: {location_key}", 404

    try:
        # 2. 更新資料庫計數 (針對該地點 +1)
        # 資料結構會變成: { "shibuya": 10, "tokyo_tower": 5, ... }
        db.db[DATABASE_NAME]['system_stats'].update_one(
            {"_id": "qr_stats"},
            {"$inc": {f"counts.{location_key}": 1}},  # 只增加該地點的計數
            upsert=True
        )
        
        # 3. 讀取最新數據以便廣播
        stats_doc = db.db[DATABASE_NAME]['system_stats'].find_one({"_id": "qr_stats"})
        current_counts = stats_doc.get("counts", {}) if stats_doc else {}
        
        # 4. 廣播給中控台 (包含所有地點的最新數據)
        socketio.emit('qr_stats_update', {
            "counts": current_counts,
            "latest_scan": location_key,  # 告訴前端剛剛是誰被掃了
            "timestamp": datetime.now().isoformat()
        })
        
        logger.info(f"👉 [{target['name']}] QR Code 被掃描! 目前累計: {current_counts.get(location_key, 0)}")
    except Exception as e:
        logger.error(f"記錄 QR Code 掃描時發生錯誤: {e}")

    # 5. 執行跳轉
    return redirect(target['url'])

@app.route('/api/v1/admin/qr_stats', methods=['GET'])
def get_qr_stats():
    """獲取所有 QR Code 統計數據 (初始化用)"""
    try:
        stats_doc = db.db[DATABASE_NAME]['system_stats'].find_one({"_id": "qr_stats"})
        counts = stats_doc.get("counts", {}) if stats_doc else {}
        
        # 確保所有定義的地點都有欄位 (即使是 0)
        result = {}
        for key, info in QR_LOCATIONS.items():
            result[key] = {
                "name": info['name'],
                "count": counts.get(key, 0)
            }
            
        return jsonify({"status": "success", "stats": result})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/v1/admin/reset_qr/<location_key>', methods=['POST'])
def reset_qr_stat(location_key):
    """歸零特定地點的計數"""
    if location_key not in QR_LOCATIONS and location_key != "all":
        return jsonify({"status": "error", "message": "無效的地點"}), 400
        
    try:
        if location_key == "all":
            # 全部歸零
            db.db[DATABASE_NAME]['system_stats'].update_one(
                {"_id": "qr_stats"},
                {"$set": {"counts": {}}}
            )
        else:
            # 指定地點歸零
            db.db[DATABASE_NAME]['system_stats'].update_one(
                {"_id": "qr_stats"},
                {"$set": {f"counts.{location_key}": 0}}
            )
            
        # 廣播更新
        socketio.emit('qr_stats_update', {
            "reset": True,
            "target": location_key,
            "timestamp": datetime.now().isoformat()
        })
        
        return jsonify({"status": "success", "message": f"{location_key} 已歸零"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

###


@app.route('/qrcod')
def qrcode_entry():
    # 這裡可以隨時改成你想導向的任何網址
    # 例如導向 Google：
    return redirect("https://drive.google.com/drive/folders/1MIyWQckNgUPCb3kTl4DbkFZ15Uc4dCTM")

@app.route('/init_db', methods=['GET'])
def init_database():
    """初始化數據庫端點"""
    try:
        # 創建地理空間索引
        index_success = db.create_indexes()
        
        # 獲取示例數據
        devices_data = SampleData.get_devices()
        advertisements_data = SampleData.get_advertisements()
        campaigns_data = SampleData.get_campaigns()
        
        # 插入示例數據
        data_success = db.insert_sample_data(
            devices_data,
            advertisements_data,
            campaigns_data
        )
        
        if index_success and data_success:
            return jsonify({
                "status": "success",
                "message": "數據庫初始化成功",
                "details": {
                    "indexes": "已創建 2dsphere 索引",
                    "devices": f"已插入 {len(devices_data)} 個設備",
                    "advertisements": f"已插入 {len(advertisements_data)} 個廣告",
                    "campaigns": f"已插入 {len(campaigns_data)} 個活動"
                }
            }), 200
        else:
            return jsonify({
                "status": "error",
                "message": "數據庫初始化過程中出現問題"
            }), 500
            
    except Exception as e:
        logger.error(f"初始化數據庫時出錯: {e}")
        return jsonify({
            "status": "error",
            "message": str(e)
        }), 500


@app.route('/api/v1/device/heartbeat', methods=['POST'])
def device_heartbeat():
    """
    傳統 HTTP 心跳端點（向後兼容）
    
    建議使用 WebSocket location_update 事件
    """
    try:
        # 1. 獲取並驗證請求數據
        data = request.get_json()
        
        is_valid, error_msg, parsed_data = HeartbeatRequest.validate(data)
        
        if not is_valid:
            return jsonify(HeartbeatResponse.error(error_msg))
        
        device_id = parsed_data['device_id']
        longitude = parsed_data['longitude']
        latitude = parsed_data['latitude']
        
        logger.info(f"收到 HTTP 心跳請求 - 設備: {device_id}, 位置: ({longitude}, {latitude})")
        
        # 2. 執行廣告決策
        ad_info = ad_service.decide_ad(device_id, longitude, latitude)
        
        # 3. 處理設備不存在的情況
        if ad_info is None:
            return jsonify(HeartbeatResponse.error(
                f"找不到設備: {device_id}",
                404
            ))
        
        video_filename = ad_info.get('video_filename')
        if not video_filename:
            return jsonify(HeartbeatResponse.error(
                "無法決定播放的廣告",
                500
            ))
        
        # 4. 嘗試通過 WebSocket 推送（如果設備在線）
        sid = get_device_sid(device_id)
        if sid:
            payload = {
                "command": "PLAY_VIDEO",
                "video_filename": video_filename,
                "advertisement_id": ad_info.get('advertisement_id'),
                "advertisement_name": ad_info.get('advertisement_name', ''),
                "trigger": "http_heartbeat",
                "device_id": device_id,
                "location": {
                    "longitude": longitude,
                    "latitude": latitude
                },
                "timestamp": datetime.now().isoformat()
            }
            
            socketio.emit('play_ad', payload, room=sid)
            connection_stats['messages_sent'] += 1

            device_playback_state[device_id] = {
                "mode": "single_play",
                "video_filename": video_filename,
                "advertisement_id": ad_info.get('advertisement_id'),
                "advertisement_name": ad_info.get('advertisement_name', ''),
                "campaign_id": ad_info.get('campaign_id'),
                "playlist": [],
                "updated_at": datetime.now().isoformat()
            }
            
            logger.info(f"已通過 WebSocket 推送廣告到 {device_id}: {video_filename}")
        
        # 5. 返回 HTTP 響應（向後兼容）
        response = HeartbeatResponse.success(video_filename)
        return jsonify(response), 200
        
    except Exception as e:
        logger.error(f"處理心跳請求時出錯: {e}", exc_info=True)
        return jsonify(HeartbeatResponse.error(
            "內部伺服器錯誤",
            500,
            str(e)
        ))


# ============================================================================
# 註冊前端管理 API Blueprint
# ============================================================================

# 初始化並註冊管理 API
admin_blueprint = init_admin_api(
    db=db,
    socketio=socketio,
    device_to_sid=device_to_sid,
    connection_stats=connection_stats,
    active_connections=active_connections,
    device_campaign_state=device_campaign_state,
    device_playback_state=device_playback_state
)
# app.register_blueprint(admin_blueprint)

# logger.info("前端管理 API 已註冊")
app.register_blueprint(admin_blueprint, url_prefix="/api/v1/admin")
logger.info("前端管理 API 已註冊 (/api/v1/admin)")

# 註冊雙螢幕控制 API (V2)
app.register_blueprint(dual_screen_bp)
logger.info("雙螢幕控制 API 已註冊 (/api/v2)")



# ============================================================================
# 靜態檔案服務 - 管理介面
# ============================================================================

@app.route('/login')
@app.route('/login.html')
def login_page():
    """提供登入頁面"""
    try:
        with open('login.html', 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        return "登入頁面不存在", 404


@app.route('/admin')
@app.route('/admin_dashboard.html')
def admin_dashboard():
    """提供管理者後台"""
    try:
        with open('admin_dashboard.html', 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        return "管理者後台檔案不存在", 404


@app.route('/control')
@app.route('/control_panel.html')
def control_panel():
    """提供雙螢幕中控台"""
    try:
        with open('control_panel.html', 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        return "中控台檔案不存在", 404


@app.route('/qr-scan')
@app.route('/qr_scan.html')
def qr_scan_page():
    """提供 QR Code 掃描頁面"""
    try:
        with open('qr_scan.html', 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        return "QR Code 掃描頁面不存在", 404


@app.route('/asset/<path:filename>')
def serve_asset(filename):
    """提供靜態資源檔案（影片等）"""
    try:
        # asset 資料夾在 src/ 目錄下（與 app.py 同級）
        current_dir = os.path.dirname(os.path.abspath(__file__))
        asset_dir = os.path.join(current_dir, 'asset')
        asset_path = os.path.join(asset_dir, filename)
        
        # 安全檢查：確保檔案路徑在 asset 目錄內（防止路徑遍歷攻擊）
        asset_path = os.path.normpath(asset_path)
        asset_dir = os.path.normpath(asset_dir)
        
        if not asset_path.startswith(asset_dir):
            logger.warning(f"嘗試訪問 asset 目錄外的檔案: {filename}")
            return jsonify({
                "status": "error",
                "message": "無效的檔案路徑"
            }), 403
        
        if not os.path.exists(asset_path):
            logger.warning(f"檔案不存在: {asset_path}")
            return jsonify({
                "status": "error",
                "message": f"檔案 {filename} 不存在"
            }), 404
        
        from flask import send_from_directory
        logger.info(f"提供靜態資源: {asset_path}")
        return send_from_directory(asset_dir, filename)
    except Exception as e:
        logger.error(f"提供靜態資源失敗: {e}", exc_info=True)
        return jsonify({
            "status": "error",
            "message": f"無法提供檔案: {str(e)}"
        }), 500


# ============================================================================
# 主程序入口
# ============================================================================

if __name__ == '__main__':
    logger.info("啟動整合版智能計程車廣告服務...")

    deployment_env = os.getenv("APP_ENV", "local")

    if deployment_env == "azure":
        public_host = "robusttaxi.azurewebsites.net"
        logger.info(f"⚙️ Azure 環境偵測到，將使用 Gunicorn 啟動伺服器。")
        logger.info(f"WebSocket 端點: wss://{public_host}")
        logger.info(f"HTTP 端點: https://{public_host}")
        logger.info(f"健康檢查端點: https://{public_host}/health")
        logger.info("👉 Azure 上的 Gunicorn 將自動啟動，這裡不再執行 socketio.run()。")
    else:
        logger.info(f"WebSocket 端點: ws://localhost:{FLASK_PORT}")
        logger.info(f"HTTP 端點: http://localhost:{FLASK_PORT}")
        logger.info(f"請先訪問 http://localhost:{FLASK_PORT}/init_db 初始化數據庫")

        # 僅在本地開發時啟動
        socketio.run(
            app,
            host="0.0.0.0",
            port=int(os.getenv("WEBSITES_PORT", FLASK_PORT)),
            debug=FLASK_DEBUG,
            allow_unsafe_werkzeug=True
        )
