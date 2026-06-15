#!/usr/bin/env python3
"""
大檔案分片上傳測試腳本
測試大空間影片的分片上傳功能
"""

import requests
import json
import os
import tempfile
import time
from datetime import datetime

# 測試配置
BASE_URL = "https://robusttaxi.azurewebsites.net"
API_BASE = f"{BASE_URL}/api/v1/admin"

def create_large_test_file(size_mb=100):
    """創建一個指定大小的測試文件"""
    temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
    
    # 寫入指定大小的數據
    chunk_size = 1024 * 1024  # 1MB
    for i in range(size_mb):
        temp_file.write(b'0' * chunk_size)
    
    temp_file.close()
    return temp_file.name

def test_chunked_upload_large_file():
    """測試大檔案分片上傳"""
    print("=== 測試大檔案分片上傳 ===")
    
    # 創建 100MB 測試文件
    test_file_path = create_large_test_file(100)
    file_size = os.path.getsize(test_file_path)
    
    print(f"創建測試文件: {test_file_path}")
    print(f"文件大小: {file_size / (1024*1024):.2f} MB")
    
    try:
        # 1. 初始化分片上傳
        chunk_size = 10 * 1024 * 1024  # 10MB
        total_chunks = (file_size + chunk_size - 1) // chunk_size
        
        print(f"分片大小: {chunk_size / (1024*1024):.2f} MB")
        print(f"總分片數: {total_chunks}")
        
        init_data = {
            "filename": "large_test_video.mp4",
            "total_size": file_size,
            "total_chunks": total_chunks,
            "name": "大檔案測試廣告",
            "advertisement_id": f"test-large-{int(time.time())}"
        }
        
        print("初始化分片上傳...")
        init_response = requests.post(f"{API_BASE}/videos/chunked/init", json=init_data)
        
        if init_response.status_code != 200:
            print(f"❌ 初始化失敗: {init_response.status_code}")
            print(init_response.text)
            return False
        
        init_result = init_response.json()
        if init_result['status'] != 'success':
            print(f"❌ 初始化失敗: {init_result['message']}")
            return False
        
        upload_id = init_result['upload_id']
        print(f"✅ 初始化成功，上傳ID: {upload_id}")
        
        # 2. 上傳分片
        print("開始上傳分片...")
        with open(test_file_path, 'rb') as f:
            for i in range(total_chunks):
                start = i * chunk_size
                end = min(start + chunk_size, file_size)
                f.seek(start)
                chunk_data = f.read(end - start)
                
                chunk_form_data = {
                    'upload_id': upload_id,
                    'chunk_number': str(i),
                    'chunk': ('chunk', chunk_data, 'application/octet-stream')
                }
                
                chunk_response = requests.post(f"{API_BASE}/videos/chunked/upload", files=chunk_form_data)
                
                if chunk_response.status_code != 200:
                    print(f"❌ 分片 {i} 上傳失敗: {chunk_response.status_code}")
                    print(chunk_response.text)
                    return False
                
                chunk_result = chunk_response.json()
                if chunk_result['status'] != 'success':
                    print(f"❌ 分片 {i} 上傳失敗: {chunk_result['message']}")
                    return False
                
                progress = ((i + 1) / total_chunks) * 100
                print(f"✅ 分片 {i + 1}/{total_chunks} 上傳成功 ({progress:.1f}%)")
        
        # 3. 完成上傳
        print("完成上傳...")
        complete_data = {"upload_id": upload_id}
        complete_response = requests.post(f"{API_BASE}/videos/chunked/complete", json=complete_data)
        
        if complete_response.status_code != 201:
            print(f"❌ 完成上傳失敗: {complete_response.status_code}")
            print(complete_response.text)
            return False
        
        complete_result = complete_response.json()
        if complete_result['status'] != 'success':
            print(f"❌ 完成上傳失敗: {complete_result['message']}")
            return False
        
        print("✅ 大檔案分片上傳成功!")
        print(f"最終文件: {complete_result['video_info']['filename']}")
        print(f"文件大小: {complete_result['video_info']['size']} bytes")
        
        return True
        
    except Exception as e:
        print(f"❌ 測試失敗: {e}")
        return False
    finally:
        # 清理測試文件
        try:
            os.unlink(test_file_path)
            print(f"清理測試文件: {test_file_path}")
        except:
            pass

def test_error_handling():
    """測試錯誤處理"""
    print("\n=== 測試錯誤處理 ===")
    
    # 測試過大的文件
    print("測試過大文件...")
    init_data = {
        "filename": "huge_file.mp4",
        "total_size": 20 * 1024 * 1024 * 1024,  # 20GB
        "total_chunks": 2000,
        "name": "超大檔案測試"
    }
    
    response = requests.post(f"{API_BASE}/videos/chunked/init", json=init_data)
    if response.status_code == 400:
        result = response.json()
        print(f"✅ 正確拒絕過大文件: {result['message']}")
    else:
        print(f"❌ 應該拒絕過大文件，但返回: {response.status_code}")
    
    # 測試過多分片
    print("測試過多分片...")
    init_data = {
        "filename": "many_chunks.mp4",
        "total_size": 100 * 1024 * 1024,  # 100MB
        "total_chunks": 15000,  # 超過限制
        "name": "過多分片測試"
    }
    
    response = requests.post(f"{API_BASE}/videos/chunked/init", json=init_data)
    if response.status_code == 400:
        result = response.json()
        print(f"✅ 正確拒絕過多分片: {result['message']}")
    else:
        print(f"❌ 應該拒絕過多分片，但返回: {response.status_code}")

def main():
    """主測試函數"""
    print("開始大檔案分片上傳測試...")
    print(f"服務器: {BASE_URL}")
    
    # 測試服務器健康狀態
    try:
        response = requests.get(f"{BASE_URL}/health")
        if response.status_code == 200:
            print("✅ 服務器健康")
        else:
            print("❌ 服務器不健康")
            return
    except Exception as e:
        print(f"❌ 無法連接到服務器: {e}")
        return
    
    # 執行測試
    success = test_chunked_upload_large_file()
    test_error_handling()
    
    if success:
        print("\n🎉 所有測試通過!")
    else:
        print("\n❌ 測試失敗")

if __name__ == "__main__":
    main()

