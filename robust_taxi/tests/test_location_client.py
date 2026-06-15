"""
測試客戶端 - 模擬設備定期發送位置數據

使用方式:
python tests/test_location_client.py [device_id] [interval_seconds]

範例:
python tests/test_location_client.py taxi-AAB-1234-rooftop 5
"""

import socketio
import time
import sys
import random
from datetime import datetime

# 創建 SocketIO 客戶端
sio = socketio.Client()

# 全局變量
device_id = None
update_interval = 5  # 預設 5 秒更新一次


# ============================================================================
# 事件處理函數
# ============================================================================

@sio.event
def connect():
    """連接成功"""
    print(f"✅ 已連接到服務器")
    print(f"📱 設備 ID: {device_id}")
    print(f"⏱️  位置更新間隔: {update_interval} 秒")
    print("-" * 60)


@sio.event
def connection_established(data):
    """收到連接確認"""
    print(f"\n📥 收到服務器歡迎消息:")
    print(f"   消息: {data.get('message')}")
    print(f"   時間: {data.get('timestamp')}")
    
    # 立即註冊設備
    print(f"\n📤 正在註冊設備: {device_id}")
    sio.emit('register', {'device_id': device_id})


@sio.event
def registration_success(data):
    """註冊成功"""
    print(f"\n✅ 設備註冊成功!")
    print(f"   設備 ID: {data.get('device_id')}")
    print(f"   設備類型: {data.get('device_type')}")
    print(f"   註冊時間: {data.get('timestamp')}")
    print("-" * 60)
    print(f"\n🚀 開始發送位置數據...\n")


@sio.event
def registration_error(data):
    """註冊失敗"""
    print(f"\n❌ 設備註冊失敗: {data.get('error')}")
    sio.disconnect()


@sio.event
def play_ad(data):
    """收到廣告播放命令"""
    print(f"\n🎬 收到廣告推送命令:")
    print(f"   命令: {data.get('command')}")
    print(f"   影片: {data.get('video_filename')}")
    print(f"   觸發: {data.get('trigger')}")
    
    if data.get('trigger') == 'location_based':
        location = data.get('location', {})
        print(f"   位置: ({location.get('longitude')}, {location.get('latitude')})")
    elif data.get('trigger') == 'admin_override':
        print(f"   優先級: {data.get('priority')}")
        print(f"   廣告名稱: {data.get('advertisement_name')}")
    
    print(f"   時間: {data.get('timestamp')}")
    print("-" * 60)


@sio.event
def location_ack(data):
    """位置更新確認"""
    video = data.get('video_filename')
    if video:
        print(f"✓ 位置已處理，推送廣告: {video}")
    else:
        print(f"✓ 位置已處理，無匹配廣告")


@sio.event
def location_error(data):
    """位置更新錯誤"""
    print(f"❌ 位置更新錯誤: {data.get('error')}")


@sio.event
def disconnect():
    """斷開連接"""
    print(f"\n\n❌ 已斷開連接")


# ============================================================================
# 位置模擬函數
# ============================================================================

# 定義幾個測試路線（台北市區域）
ROUTES = {
    'route_1': [
        # 在信義區商圈範圍內移動
        (121.5645, 25.0330),  # 台北 101
        (121.5635, 25.0335),
        (121.5625, 25.0340),
        (121.5615, 25.0345),
    ],
    'route_2': [
        # 在西門町商圈範圍內移動
        (121.5070, 25.0420),  # 西門町
        (121.5075, 25.0425),
        (121.5080, 25.0430),
        (121.5085, 25.0435),
    ],
    'route_3': [
        # 隨機移動（不在特定商圈內）
        (121.5200, 25.0400),
        (121.5250, 25.0450),
        (121.5300, 25.0500),
        (121.5350, 25.0550),
    ]
}

current_route = 'route_1'
current_position_index = 0


def get_next_location():
    """獲取下一個位置（模擬 GPS 移動）"""
    global current_position_index, current_route
    
    route_positions = ROUTES[current_route]
    location = route_positions[current_position_index]
    
    # 移動到下一個位置
    current_position_index = (current_position_index + 1) % len(route_positions)
    
    # 添加一些隨機抖動（模擬 GPS 精度）
    longitude = location[0] + random.uniform(-0.0005, 0.0005)
    latitude = location[1] + random.uniform(-0.0005, 0.0005)
    
    return longitude, latitude


def switch_route():
    """切換路線"""
    global current_route, current_position_index
    routes = list(ROUTES.keys())
    current_route = random.choice(routes)
    current_position_index = 0
    print(f"\n🔄 切換到新路線: {current_route}")


# ============================================================================
# 主循環
# ============================================================================

def send_location_updates():
    """定期發送位置更新"""
    update_count = 0
    
    try:
        while True:
            time.sleep(update_interval)
            
            # 獲取當前位置
            longitude, latitude = get_next_location()
            update_count += 1
            
            # 發送位置更新
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            print(f"\n[{timestamp}] 📍 發送位置更新 #{update_count}:")
            print(f"   經度: {longitude:.6f}, 緯度: {latitude:.6f}")
            
            sio.emit('location_update', {
                'device_id': device_id,
                'longitude': longitude,
                'latitude': latitude,
                'timestamp': timestamp
            })
            
            # 每 10 次更新切換一次路線
            if update_count % 10 == 0:
                switch_route()
                
    except KeyboardInterrupt:
        print(f"\n\n⚠️  收到中斷信號，正在斷開連接...")
        sio.disconnect()


# ============================================================================
# 主程序
# ============================================================================

def main():
    global device_id, update_interval
    
    # 解析命令行參數
    if len(sys.argv) >= 2:
        device_id = sys.argv[1]
    else:
        device_id = 'taxi-AAB-1234-rooftop'  # 預設設備
    
    if len(sys.argv) >= 3:
        try:
            update_interval = int(sys.argv[2])
        except ValueError:
            print("⚠️  更新間隔必須是整數，使用預設值 5 秒")
            update_interval = 5
    
    # 連接到服務器
    server_url = 'https://robusttaxi.azurewebsites.net'
    
    print("=" * 60)
    print("🚕 智能計程車位置更新測試客戶端")
    print("=" * 60)
    print(f"📡 正在連接到服務器: {server_url}")
    
    try:
        sio.connect(server_url)
        
        # 開始發送位置更新
        send_location_updates()
        
    except Exception as e:
        print(f"\n❌ 連接失敗: {e}")
        print(f"\n💡 請確保服務器正在運行: python run_app.py")


if __name__ == '__main__':
    main()

