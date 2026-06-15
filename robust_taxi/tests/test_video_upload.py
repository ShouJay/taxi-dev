#!/usr/bin/env python3
"""
影片上傳功能測試腳本
測試影片上傳、廣告管理和推送功能
"""

import requests
import json
import os
import tempfile
import time

# 測試配置
BASE_URL = "https://robusttaxi.azurewebsites.net"
API_BASE = f"{BASE_URL}/api/v1/admin"

def create_test_video():
    """創建一個測試影片文件（實際上是文本文件，用於測試）"""
    # 創建一個臨時的測試文件
    test_content = b"Test video content for upload testing"
    temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
    temp_file.write(test_content)
    temp_file.close()
    return temp_file.name

def test_video_upload():
    """測試影片上傳功能"""
    print("=== 測試影片上傳功能 ===")
    
    # 創建測試文件
    test_file_path = create_test_video()
    
    try:
        # 準備上傳數據
        with open(test_file_path, 'rb') as f:
            files = {'file': ('test_video.mp4', f, 'video/mp4')}
            data = {
                'name': '測試廣告',
                'advertisement_id': 'test-adv-001'
            }
            
            # 發送上傳請求
            response = requests.post(f"{API_BASE}/videos/upload", files=files, data=data)
            
            print(f"上傳響應狀態碼: {response.status_code}")
            print(f"上傳響應內容: {response.json()}")
            
            if response.status_code == 201:
                print("✅ 影片上傳成功")
                return response.json()['video_info']['advertisement_id']
            else:
                print("❌ 影片上傳失敗")
                return None
                
    except Exception as e:
        print(f"❌ 上傳測試出錯: {e}")
        return None
    finally:
        # 清理測試文件
        os.unlink(test_file_path)

def test_get_video_info(advertisement_id):
    """測試獲取影片信息"""
    print(f"\n=== 測試獲取影片信息: {advertisement_id} ===")
    
    try:
        response = requests.get(f"{API_BASE}/videos/{advertisement_id}")
        
        print(f"獲取信息響應狀態碼: {response.status_code}")
        print(f"獲取信息響應內容: {response.json()}")
        
        if response.status_code == 200:
            print("✅ 獲取影片信息成功")
            return True
        else:
            print("❌ 獲取影片信息失敗")
            return False
            
    except Exception as e:
        print(f"❌ 獲取信息測試出錯: {e}")
        return False

def test_get_available_advertisements():
    """測試獲取可用廣告列表"""
    print(f"\n=== 測試獲取可用廣告列表 ===")
    
    try:
        # 測試基本查詢
        response = requests.get(f"{API_BASE}/advertisements/available")
        
        print(f"獲取列表響應狀態碼: {response.status_code}")
        print(f"獲取列表響應內容: {response.json()}")
        
        if response.status_code == 200:
            print("✅ 獲取廣告列表成功")
            
            # 測試只返回有文件的廣告
            response_with_files = requests.get(f"{API_BASE}/advertisements/available?with_files=true")
            print(f"只返回有文件的廣告: {response_with_files.json()}")
            
            return True
        else:
            print("❌ 獲取廣告列表失敗")
            return False
            
    except Exception as e:
        print(f"❌ 獲取列表測試出錯: {e}")
        return False

def test_advertisement_management():
    """測試廣告管理功能"""
    print(f"\n=== 測試廣告管理功能 ===")
    
    try:
        # 獲取廣告列表
        response = requests.get(f"{API_BASE}/advertisements")
        
        print(f"廣告管理響應狀態碼: {response.status_code}")
        print(f"廣告管理響應內容: {response.json()}")
        
        if response.status_code == 200:
            print("✅ 廣告管理功能正常")
            return True
        else:
            print("❌ 廣告管理功能異常")
            return False
            
    except Exception as e:
        print(f"❌ 廣告管理測試出錯: {e}")
        return False

def test_push_functionality(advertisement_id):
    """測試推送功能"""
    print(f"\n=== 測試推送功能: {advertisement_id} ===")
    
    try:
        # 準備推送數據
        push_data = {
            "target_device_ids": ["taxi-AAB-1234-rooftop"],  # 使用示例設備ID
            "advertisement_id": advertisement_id
        }
        
        response = requests.post(f"{API_BASE}/override", json=push_data)
        
        print(f"推送響應狀態碼: {response.status_code}")
        print(f"推送響應內容: {response.json()}")
        
        if response.status_code == 200:
            print("✅ 推送功能正常")
            return True
        else:
            print("❌ 推送功能異常")
            return False
            
    except Exception as e:
        print(f"❌ 推送測試出錯: {e}")
        return False

def test_health_check():
    """測試健康檢查"""
    print(f"\n=== 測試健康檢查 ===")
    
    try:
        response = requests.get(f"{BASE_URL}/health")
        
        print(f"健康檢查響應狀態碼: {response.status_code}")
        print(f"健康檢查響應內容: {response.json()}")
        
        if response.status_code == 200:
            print("✅ 服務健康檢查通過")
            return True
        else:
            print("❌ 服務健康檢查失敗")
            return False
            
    except Exception as e:
        print(f"❌ 健康檢查出錯: {e}")
        return False

def cleanup_test_data(advertisement_id):
    """清理測試數據"""
    print(f"\n=== 清理測試數據: {advertisement_id} ===")
    
    try:
        response = requests.delete(f"{API_BASE}/videos/{advertisement_id}")
        
        print(f"清理響應狀態碼: {response.status_code}")
        print(f"清理響應內容: {response.json()}")
        
        if response.status_code == 200:
            print("✅ 測試數據清理成功")
            return True
        else:
            print("❌ 測試數據清理失敗")
            return False
            
    except Exception as e:
        print(f"❌ 清理測試出錯: {e}")
        return False

def main():
    """主測試函數"""
    print("開始影片上傳功能測試...")
    print(f"測試服務器: {BASE_URL}")
    
    # 測試健康檢查
    if not test_health_check():
        print("❌ 服務器不可用，請確保服務器正在運行")
        return
    
    # 測試影片上傳
    advertisement_id = test_video_upload()
    if not advertisement_id:
        print("❌ 影片上傳失敗，無法繼續測試")
        return
    
    # 測試獲取影片信息
    test_get_video_info(advertisement_id)
    
    # 測試獲取可用廣告列表
    test_get_available_advertisements()
    
    # 測試廣告管理功能
    test_advertisement_management()
    
    # 測試推送功能
    test_push_functionality(advertisement_id)
    
    # 清理測試數據
    cleanup_test_data(advertisement_id)
    
    print("\n=== 測試完成 ===")
    print("所有功能測試已完成，請檢查上述輸出結果")

if __name__ == "__main__":
    main()
