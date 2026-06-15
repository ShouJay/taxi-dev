#!/usr/bin/env python3
"""
分片上傳功能測試腳本
測試分片上傳、分片下載和傳統上傳功能
"""

import requests
import json
import os
import tempfile
import time
import math

# 測試配置
BASE_URL = "https://robusttaxi.azurewebsites.net"
API_BASE = f"{BASE_URL}/api/v1/admin"
CHUNK_SIZE = 5 * 1024 * 1024  # 5MB

def create_test_video(size_mb=10):
    """創建指定大小的測試影片文件"""
    size_bytes = size_mb * 1024 * 1024
    test_content = b"A" * size_bytes  # 創建指定大小的測試數據
    
    temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
    temp_file.write(test_content)
    temp_file.close()
    return temp_file.name

def test_chunked_upload(size_mb=10):
    """測試分片上傳功能"""
    print(f"=== 測試分片上傳功能 ({size_mb}MB) ===")
    
    # 創建測試文件
    test_file_path = create_test_video(size_mb)
    file_size = os.path.getsize(test_file_path)
    total_chunks = math.ceil(file_size / CHUNK_SIZE)
    
    try:
        # 1. 初始化分片上傳
        print("1. 初始化分片上傳...")
        init_data = {
            "filename": "test_chunked_video.mp4",
            "total_size": file_size,
            "total_chunks": total_chunks,
            "name": f"分片測試廣告 ({size_mb}MB)",
            "advertisement_id": f"test-chunked-{size_mb}mb"
        }
        
        init_response = requests.post(f"{API_BASE}/videos/chunked/init", json=init_data)
        
        if init_response.status_code != 200:
            print(f"❌ 初始化失敗: {init_response.json()}")
            return None
        
        init_result = init_response.json()
        upload_id = init_result['upload_id']
        print(f"✅ 初始化成功，上傳ID: {upload_id}")
        
        # 2. 上傳分片
        print(f"2. 上傳 {total_chunks} 個分片...")
        
        with open(test_file_path, 'rb') as f:
            for chunk_number in range(total_chunks):
                start = chunk_number * CHUNK_SIZE
                end = min(start + CHUNK_SIZE, file_size)
                f.seek(start)
                chunk_data = f.read(end - start)
                
                files = {'chunk': ('chunk', chunk_data, 'application/octet-stream')}
                data = {
                    'upload_id': upload_id,
                    'chunk_number': chunk_number
                }
                
                chunk_response = requests.post(f"{API_BASE}/videos/chunked/upload", files=files, data=data)
                
                if chunk_response.status_code != 200:
                    print(f"❌ 分片 {chunk_number} 上傳失敗: {chunk_response.json()}")
                    return None
                
                chunk_result = chunk_response.json()
                progress = chunk_result['progress']
                print(f"   分片 {chunk_number + 1}/{total_chunks} 上傳成功 ({progress}%)")
        
        # 3. 完成上傳
        print("3. 完成上傳...")
        complete_data = {"upload_id": upload_id}
        complete_response = requests.post(f"{API_BASE}/videos/chunked/complete", json=complete_data)
        
        if complete_response.status_code != 201:
            print(f"❌ 完成上傳失敗: {complete_response.json()}")
            return None
        
        complete_result = complete_response.json()
        print(f"✅ 分片上傳完成！廣告ID: {complete_result['video_info']['advertisement_id']}")
        
        return complete_result['video_info']['advertisement_id']
        
    except Exception as e:
        print(f"❌ 分片上傳測試出錯: {e}")
        return None
    finally:
        # 清理測試文件
        os.unlink(test_file_path)

def test_chunked_download(advertisement_id):
    """測試分片下載功能"""
    print(f"\n=== 測試分片下載功能: {advertisement_id} ===")
    
    try:
        # 1. 獲取下載信息
        print("1. 獲取下載信息...")
        download_response = requests.get(f"{API_BASE}/videos/{advertisement_id}/download?chunked=true")
        
        if download_response.status_code != 200:
            print(f"❌ 獲取下載信息失敗: {download_response.json()}")
            return False
        
        download_info = download_response.json()['download_info']
        total_chunks = download_info['total_chunks']
        chunk_size = download_info['chunk_size']
        
        print(f"✅ 下載信息獲取成功，共 {total_chunks} 個分片")
        
        # 2. 下載分片
        print("2. 下載分片...")
        downloaded_data = b""
        
        for chunk_number in range(total_chunks):
            chunk_response = requests.get(f"{API_BASE}/videos/{advertisement_id}/chunk?chunk={chunk_number}&chunk_size={chunk_size}")
            
            if chunk_response.status_code != 200:
                print(f"❌ 分片 {chunk_number} 下載失敗")
                return False
            
            downloaded_data += chunk_response.content
            print(f"   分片 {chunk_number + 1}/{total_chunks} 下載成功")
        
        print(f"✅ 分片下載完成，總大小: {len(downloaded_data)} bytes")
        return True
        
    except Exception as e:
        print(f"❌ 分片下載測試出錯: {e}")
        return False

def test_normal_upload():
    """測試傳統上傳功能"""
    print(f"\n=== 測試傳統上傳功能 ===")
    
    # 創建小文件測試
    test_file_path = create_test_video(5)  # 5MB
    
    try:
        with open(test_file_path, 'rb') as f:
            files = {'file': ('test_normal_video.mp4', f, 'video/mp4')}
            data = {
                'name': '傳統上傳測試廣告',
                'advertisement_id': 'test-normal-5mb'
            }
            
            response = requests.post(f"{API_BASE}/videos/upload", files=files, data=data)
            
            if response.status_code == 201:
                result = response.json()
                print(f"✅ 傳統上傳成功！廣告ID: {result['video_info']['advertisement_id']}")
                return result['video_info']['advertisement_id']
            else:
                print(f"❌ 傳統上傳失敗: {response.json()}")
                return None
                
    except Exception as e:
        print(f"❌ 傳統上傳測試出錯: {e}")
        return None
    finally:
        os.unlink(test_file_path)

def test_large_file_upload():
    """測試大文件上傳"""
    print(f"\n=== 測試大文件上傳 (50MB) ===")
    
    # 創建大文件測試
    test_file_path = create_test_video(50)  # 50MB
    
    try:
        with open(test_file_path, 'rb') as f:
            files = {'file': ('test_large_video.mp4', f, 'video/mp4')}
            data = {
                'name': '大文件上傳測試廣告',
                'advertisement_id': 'test-large-50mb'
            }
            
            response = requests.post(f"{API_BASE}/videos/upload", files=files, data=data)
            
            if response.status_code == 201:
                result = response.json()
                print(f"✅ 大文件上傳成功！廣告ID: {result['video_info']['advertisement_id']}")
                return result['video_info']['advertisement_id']
            else:
                print(f"❌ 大文件上傳失敗: {response.json()}")
                return None
                
    except Exception as e:
        print(f"❌ 大文件上傳測試出錯: {e}")
        return None
    finally:
        os.unlink(test_file_path)

def cleanup_test_data(advertisement_ids):
    """清理測試數據"""
    print(f"\n=== 清理測試數據 ===")
    
    for ad_id in advertisement_ids:
        if ad_id:
            try:
                response = requests.delete(f"{API_BASE}/videos/{ad_id}")
                
                if response.status_code == 200:
                    print(f"✅ 廣告 {ad_id} 已刪除")
                else:
                    print(f"❌ 刪除廣告 {ad_id} 失敗: {response.json()}")
                    
            except Exception as e:
                print(f"❌ 刪除廣告 {ad_id} 出錯: {e}")

def test_health_check():
    """測試健康檢查"""
    print(f"\n=== 測試健康檢查 ===")
    
    try:
        response = requests.get(f"{BASE_URL}/health")
        
        if response.status_code == 200:
            print("✅ 服務健康檢查通過")
            return True
        else:
            print("❌ 服務健康檢查失敗")
            return False
            
    except Exception as e:
        print(f"❌ 健康檢查出錯: {e}")
        return False

def main():
    """主測試函數"""
    print("開始分片上傳功能測試...")
    print(f"測試服務器: {BASE_URL}")
    print(f"分片大小: {CHUNK_SIZE // (1024*1024)}MB")
    
    # 測試健康檢查
    if not test_health_check():
        print("❌ 服務器不可用，請確保服務器正在運行")
        return
    
    advertisement_ids = []
    
    # 測試傳統上傳
    normal_ad_id = test_normal_upload()
    if normal_ad_id:
        advertisement_ids.append(normal_ad_id)
    
    # 測試分片上傳 (10MB)
    chunked_ad_id = test_chunked_upload(10)
    if chunked_ad_id:
        advertisement_ids.append(chunked_ad_id)
        # 測試分片下載
        test_chunked_download(chunked_ad_id)
    
    # 測試大文件上傳 (50MB)
    large_ad_id = test_large_file_upload()
    if large_ad_id:
        advertisement_ids.append(large_ad_id)
    
    # 測試更大的分片上傳 (100MB)
    large_chunked_ad_id = test_chunked_upload(100)
    if large_chunked_ad_id:
        advertisement_ids.append(large_chunked_ad_id)
        # 測試分片下載
        test_chunked_download(large_chunked_ad_id)
    
    # 清理測試數據
    cleanup_test_data(advertisement_ids)
    
    print("\n=== 測試完成 ===")
    print("所有分片上傳功能測試已完成，請檢查上述輸出結果")

if __name__ == "__main__":
    main()
