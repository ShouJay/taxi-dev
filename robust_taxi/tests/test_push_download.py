#!/usr/bin/env python3
"""
管理端推送下載命令測試腳本
測試後端主動推送廣告下載命令到設備
"""

import requests
import json
import time

# 測試配置
BASE_URL = "https://robusttaxi.azurewebsites.net"
API_BASE = f"{BASE_URL}/api/v1/admin"

def test_push_single_download():
    """測試推送單個廣告下載"""
    print("=== 測試推送單個廣告下載 ===")
    
    try:
        # 推送下載命令
        push_data = {
            "target_device_ids": ["taxi-AAB-1234-rooftop"],
            "advertisement_id": "test-chunked-10mb",  # 假設這個廣告存在
            "priority": "high",
            "download_mode": "chunked"
        }
        
        response = requests.post(f"{API_BASE}/push/download", json=push_data)
        
        print(f"推送響應狀態碼: {response.status_code}")
        print(f"推送響應內容: {json.dumps(response.json(), indent=2, ensure_ascii=False)}")
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ 推送成功!")
            print(f"   發送到: {len(result['results']['sent'])} 個設備")
            print(f"   離線設備: {len(result['results']['offline'])} 個")
            return True
        else:
            print(f"❌ 推送失敗: {response.json()}")
            return False
            
    except Exception as e:
        print(f"❌ 推送測試出錯: {e}")
        return False

def test_push_batch_download():
    """測試批量推送下載"""
    print("\n=== 測試批量推送下載 ===")
    
    try:
        # 批量推送下載命令
        batch_data = {
            "target_device_ids": ["taxi-AAB-1234-rooftop", "taxi-BBC-5678-rooftop"],
            "advertisement_ids": ["test-chunked-10mb", "test-normal-5mb"],
            "priority": "normal",
            "download_mode": "chunked"
        }
        
        response = requests.post(f"{API_BASE}/push/batch", json=batch_data)
        
        print(f"批量推送響應狀態碼: {response.status_code}")
        print(f"批量推送響應內容: {json.dumps(response.json(), indent=2, ensure_ascii=False)}")
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ 批量推送成功!")
            print(f"   總廣告數: {result['summary']['total_advertisements']}")
            print(f"   總設備數: {result['summary']['total_devices']}")
            print(f"   總發送數: {result['summary']['total_sent']}")
            print(f"   總失敗數: {result['summary']['total_failed']}")
            return True
        else:
            print(f"❌ 批量推送失敗: {response.json()}")
            return False
            
    except Exception as e:
        print(f"❌ 批量推送測試出錯: {e}")
        return False

def test_get_available_advertisements():
    """測試獲取可用廣告列表"""
    print("\n=== 測試獲取可用廣告列表 ===")
    
    try:
        # 獲取可用廣告
        response = requests.get(f"{API_BASE}/advertisements/available?with_files=true")
        
        print(f"廣告列表響應狀態碼: {response.status_code}")
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ 獲取廣告列表成功!")
            print(f"   總廣告數: {result['total']}")
            
            for ad in result['advertisements']:
                print(f"   - {ad['advertisement_id']}: {ad['name']} ({ad['file_size']} bytes)")
            
            return result['advertisements']
        else:
            print(f"❌ 獲取廣告列表失敗: {response.json()}")
            return []
            
    except Exception as e:
        print(f"❌ 獲取廣告列表出錯: {e}")
        return []

def test_get_connections():
    """測試獲取連接狀態"""
    print("\n=== 測試獲取連接狀態 ===")
    
    try:
        response = requests.get(f"{API_BASE}/connections")
        
        print(f"連接狀態響應狀態碼: {response.status_code}")
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ 獲取連接狀態成功!")
            print(f"   活動設備數: {len(result['active_devices'])}")
            
            for device in result['active_devices']:
                print(f"   - {device['device_id']}: 連接時間 {device['connected_at']}")
            
            return result['active_devices']
        else:
            print(f"❌ 獲取連接狀態失敗: {response.json()}")
            return []
            
    except Exception as e:
        print(f"❌ 獲取連接狀態出錯: {e}")
        return []

def interactive_push():
    """交互式推送測試"""
    print("\n=== 交互式推送測試 ===")
    
    try:
        # 獲取可用廣告
        advertisements = test_get_available_advertisements()
        if not advertisements:
            print("❌ 沒有可用的廣告")
            return
        
        # 獲取活動設備
        active_devices = test_get_connections()
        if not active_devices:
            print("❌ 沒有活動的設備")
            return
        
        # 選擇廣告
        print("\n可用的廣告:")
        for i, ad in enumerate(advertisements):
            print(f"   {i+1}. {ad['advertisement_id']}: {ad['name']}")
        
        ad_choice = input("請選擇廣告編號: ").strip()
        try:
            ad_index = int(ad_choice) - 1
            if 0 <= ad_index < len(advertisements):
                selected_ad = advertisements[ad_index]
            else:
                print("❌ 無效的廣告編號")
                return
        except ValueError:
            print("❌ 請輸入有效的數字")
            return
        
        # 選擇設備
        print("\n活動的設備:")
        for i, device in enumerate(active_devices):
            print(f"   {i+1}. {device['device_id']}")
        
        device_choice = input("請選擇設備編號 (輸入 'all' 選擇所有設備): ").strip()
        
        if device_choice.lower() == 'all':
            target_devices = [device['device_id'] for device in active_devices]
        else:
            try:
                device_index = int(device_choice) - 1
                if 0 <= device_index < len(active_devices):
                    target_devices = [active_devices[device_index]['device_id']]
                else:
                    print("❌ 無效的設備編號")
                    return
            except ValueError:
                print("❌ 請輸入有效的數字或 'all'")
                return
        
        # 選擇下載模式
        print("\n下載模式:")
        print("   1. chunked (分片下載)")
        print("   2. normal (傳統下載)")
        
        mode_choice = input("請選擇下載模式 (1-2): ").strip()
        download_mode = "chunked" if mode_choice == "1" else "normal"
        
        # 執行推送
        push_data = {
            "target_device_ids": target_devices,
            "advertisement_id": selected_ad['advertisement_id'],
            "priority": "high",
            "download_mode": download_mode
        }
        
        print(f"\n🚀 推送下載命令...")
        print(f"   目標設備: {target_devices}")
        print(f"   廣告: {selected_ad['advertisement_id']}")
        print(f"   下載模式: {download_mode}")
        
        response = requests.post(f"{API_BASE}/push/download", json=push_data)
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ 推送成功!")
            print(f"   發送到: {result['results']['sent']}")
            print(f"   離線設備: {result['results']['offline']}")
        else:
            print(f"❌ 推送失敗: {response.json()}")
            
    except KeyboardInterrupt:
        print("\n🛑 交互式測試中斷")
    except Exception as e:
        print(f"❌ 交互式測試出錯: {e}")

def test_health_check():
    """測試健康檢查"""
    print("=== 測試健康檢查 ===")
    
    try:
        response = requests.get(f"{BASE_URL}/health")
        
        if response.status_code == 200:
            health_data = response.json()
            print(f"✅ 服務器健康: {health_data['status']}")
            print(f"   數據庫: {health_data['database']}")
            print(f"   活動連接: {health_data['active_connections']}")
            return True
        else:
            print(f"❌ 服務器不健康: {response.status_code}")
            return False
            
    except Exception as e:
        print(f"❌ 健康檢查失敗: {e}")
        return False

def main():
    """主測試函數"""
    print("開始管理端推送下載命令測試...")
    print(f"服務器: {BASE_URL}")
    
    # 測試服務器健康狀態
    if not test_health_check():
        print("❌ 服務器不可用，請確保服務器正在運行")
        return
    
    # 選擇測試模式
    print("\n請選擇測試模式:")
    print("1. 推送單個廣告下載")
    print("2. 批量推送下載")
    print("3. 交互式推送測試")
    print("4. 退出")
    
    try:
        choice = input("請輸入選擇 (1-4): ").strip()
        
        if choice == "1":
            test_push_single_download()
        elif choice == "2":
            test_push_batch_download()
        elif choice == "3":
            interactive_push()
        elif choice == "4":
            print("👋 測試結束")
        else:
            print("❌ 無效選擇")
            
    except KeyboardInterrupt:
        print("\n👋 測試結束")
    except Exception as e:
        print(f"❌ 測試出錯: {e}")

if __name__ == "__main__":
    main()
