"""
管理員推送測試腳本

使用方式:
python tests/test_admin_push.py [device_ids] [advertisement_id]

範例:
python tests/test_admin_push.py "taxi-AAB-1234-rooftop,taxi-BBB-5678-rooftop" adv-002
"""

import requests
import sys
import json
from datetime import datetime


def send_admin_override(target_device_ids, advertisement_id, server_url='https://robusttaxi.azurewebsites.net'):
    """發送管理員推送命令"""
    
    endpoint = f"{server_url}/api/v1/admin/override"
    
    payload = {
        "target_device_ids": target_device_ids,
        "advertisement_id": advertisement_id
    }
    
    print("=" * 60)
    print("🔐 管理員廣告推送測試")
    print("=" * 60)
    print(f"📡 服務器: {server_url}")
    print(f"🎯 目標設備: {', '.join(target_device_ids)}")
    print(f"📺 廣告 ID: {advertisement_id}")
    print(f"⏰ 時間: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("-" * 60)
    
    try:
        print(f"\n📤 正在發送推送請求...")
        response = requests.post(endpoint, json=payload, timeout=10)
        
        print(f"\n📥 收到響應:")
        print(f"   狀態碼: {response.status_code}")
        
        if response.status_code == 200:
            data = response.json()
            
            print(f"\n✅ 推送成功!")
            print(f"\n📺 廣告信息:")
            ad_info = data.get('advertisement', {})
            print(f"   ID: {ad_info.get('id')}")
            print(f"   名稱: {ad_info.get('name')}")
            print(f"   影片: {ad_info.get('video_filename')}")
            print(f"   類型: {ad_info.get('type')}")
            
            print(f"\n📊 推送結果:")
            summary = data.get('summary', {})
            print(f"   總目標數: {summary.get('total_targets')}")
            print(f"   成功發送: {summary.get('sent_count')}")
            print(f"   離線設備: {summary.get('offline_count')}")
            
            results = data.get('results', {})
            
            if results.get('sent'):
                print(f"\n✓ 已發送到:")
                for device in results['sent']:
                    print(f"   - {device}")
            
            if results.get('offline'):
                print(f"\n✗ 離線設備:")
                for device in results['offline']:
                    print(f"   - {device}")
            
            print(f"\n⏰ 推送時間: {data.get('timestamp')}")
            
        else:
            print(f"\n❌ 推送失敗!")
            try:
                error_data = response.json()
                print(f"   錯誤: {error_data.get('message')}")
                if 'detail' in error_data:
                    print(f"   詳情: {error_data.get('detail')}")
            except:
                print(f"   響應: {response.text}")
        
        print("=" * 60)
        
    except requests.exceptions.ConnectionError:
        print(f"\n❌ 連接失敗: 無法連接到服務器")
        print(f"💡 請確保服務器正在運行: python run_app.py")
    except requests.exceptions.Timeout:
        print(f"\n❌ 請求超時")
    except Exception as e:
        print(f"\n❌ 發生錯誤: {e}")


def get_connection_status(server_url='https://robusttaxi.azurewebsites.net'):
    """獲取當前連接狀態"""
    
    endpoint = f"{server_url}/api/v1/admin/connections"
    
    print("\n📊 正在獲取連接狀態...")
    
    try:
        response = requests.get(endpoint, timeout=10)
        
        if response.status_code == 200:
            data = response.json()
            stats = data.get('stats', {})
            active_devices = data.get('active_devices', [])
            
            print(f"\n📈 連接統計:")
            print(f"   總連接數: {stats.get('total_connections')}")
            print(f"   活動設備: {stats.get('active_devices')}")
            print(f"   已發送消息: {stats.get('messages_sent')}")
            print(f"   位置更新: {stats.get('location_updates')}")
            
            if active_devices:
                print(f"\n📱 活動設備列表:")
                for device in active_devices:
                    print(f"   - {device.get('device_id')}")
                    print(f"     連接時間: {device.get('connected_at')}")
                    print(f"     最後活動: {device.get('last_activity')}")
            else:
                print(f"\n⚠️  當前沒有活動設備")
            
        else:
            print(f"❌ 獲取狀態失敗: {response.status_code}")
    
    except Exception as e:
        print(f"❌ 獲取狀態失敗: {e}")


def main():
    # 解析命令行參數
    if len(sys.argv) >= 3:
        device_ids_str = sys.argv[1]
        advertisement_id = sys.argv[2]
        target_device_ids = [d.strip() for d in device_ids_str.split(',')]
    else:
        print("使用方式: python tests/test_admin_push.py [device_ids] [advertisement_id]")
        print("\n範例:")
        print('  python tests/test_admin_push.py "taxi-AAB-1234-rooftop,taxi-BBB-5678-rooftop" adv-002')
        print('  python tests/test_admin_push.py "taxi-AAB-1234-rooftop" adv-001')
        print("\n使用預設值進行測試...")
        target_device_ids = ['taxi-AAB-1234-rooftop']
        advertisement_id = 'adv-002'
    
    # 首先獲取連接狀態
    get_connection_status()
    
    print("\n" + "=" * 60)
    input("\n按 Enter 繼續發送推送命令...")
    
    # 發送推送命令
    send_admin_override(target_device_ids, advertisement_id)


if __name__ == '__main__':
    main()

