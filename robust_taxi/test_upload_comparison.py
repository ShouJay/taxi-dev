#!/usr/bin/env python3
"""
比較分片上傳和一般上傳的測試腳本
"""

import requests
import json
import os
import tempfile
import time

# 測試配置
BASE_URL = "https://robusttaxi.azurewebsites.net"
API_BASE = f"{BASE_URL}/api/v1/admin"

def create_test_file(size_mb=5):
    """創建測試文件"""
    temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
    chunk_size = 1024 * 1024  # 1MB
    for i in range(size_mb):
        temp_file.write(b'0' * chunk_size)
    temp_file.close()
    return temp_file.name

def test_normal_upload():
    """測試一般上傳"""
    print("=== 測試一般上傳 ===")
    
    test_file_path = create_test_file(5)  # 5MB
    
    try:
        with open(test_file_path, 'rb') as f:
            files = {'file': ('test_normal.mp4', f, 'video/mp4')}
            data = {
                'name': '一般上傳測試',
                'advertisement_id': f'normal-test-{int(time.time())}'
            }
            
            response = requests.post(f"{API_BASE}/videos/upload", files=files, data=data)
            
            print(f"狀態碼: {response.status_code}")
            print(f"回應: {json.dumps(response.json(), indent=2, ensure_ascii=False)}")
            
            if response.status_code == 201:
                print("✅ 一般上傳成功")
                return True
            else:
                print("❌ 一般上傳失敗")
                return False
                
    except Exception as e:
        print(f"❌ 錯誤: {e}")
        return False
    finally:
        os.unlink(test_file_path)

def test_chunked_upload():
    """測試分片上傳"""
    print("\n=== 測試分片上傳 ===")
    
    test_file_path = create_test_file(5)  # 5MB
    file_size = os.path.getsize(test_file_path)
    
    try:
        # 1. 初始化
        chunk_size = 10 * 1024 * 1024  # 10MB
        total_chunks = (file_size + chunk_size - 1) // chunk_size
        
        init_data = {
            "filename": "test_chunked.mp4",
            "total_size": file_size,
            "total_chunks": total_chunks,
            "name": "分片上傳測試",
            "advertisement_id": f"chunked-test-{int(time.time())}"
        }
        
        print("1. 初始化分片上傳...")
        init_response = requests.post(f"{API_BASE}/videos/chunked/init", json=init_data)
        print(f"   狀態碼: {init_response.status_code}")
        print(f"   回應: {json.dumps(init_response.json(), indent=2, ensure_ascii=False)}")
        
        if init_response.status_code != 200:
            print("❌ 初始化失敗")
            return False
        
        upload_id = init_response.json()['upload_id']
        
        # 2. 上傳分片
        print("2. 上傳分片...")
        with open(test_file_path, 'rb') as f:
            for i in range(total_chunks):
                start = i * chunk_size
                end = min(start + chunk_size, file_size)
                f.seek(start)
                chunk_data = f.read(end - start)
                
                # 使用 multipart/form-data
                files = {
                    'chunk': ('chunk', chunk_data, 'application/octet-stream')
                }
                data = {
                    'upload_id': upload_id,
                    'chunk_number': str(i)  # 確保是字符串
                }
                
                chunk_response = requests.post(
                    f"{API_BASE}/videos/chunked/upload", 
                    files=files, 
                    data=data
                )
                
                print(f"   分片 {i}: 狀態碼 {chunk_response.status_code}")
                if chunk_response.status_code != 200:
                    print(f"   錯誤: {chunk_response.text}")
                    return False
        
        # 3. 完成上傳
        print("3. 完成上傳...")
        complete_data = {"upload_id": upload_id}
        complete_response = requests.post(
            f"{API_BASE}/videos/chunked/complete", 
            json=complete_data
        )
        
        print(f"   狀態碼: {complete_response.status_code}")
        print(f"   回應: {json.dumps(complete_response.json(), indent=2, ensure_ascii=False)}")
        
        if complete_response.status_code == 201:
            print("✅ 分片上傳成功")
            return True
        else:
            print("❌ 分片上傳失敗")
            return False
            
    except Exception as e:
        print(f"❌ 錯誤: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        os.unlink(test_file_path)

def main():
    """主測試函數"""
    print("開始比較上傳測試...")
    print(f"服務器: {BASE_URL}\n")
    
    # 測試服務器
    try:
        response = requests.get(f"{BASE_URL}/health")
        if response.status_code != 200:
            print("❌ 服務器不健康")
            return
    except Exception as e:
        print(f"❌ 無法連接到服務器: {e}")
        return
    
    # 執行測試
    normal_success = test_normal_upload()
    chunked_success = test_chunked_upload()
    
    print("\n=== 測試結果 ===")
    print(f"一般上傳: {'✅ 成功' if normal_success else '❌ 失敗'}")
    print(f"分片上傳: {'✅ 成功' if chunked_success else '❌ 失敗'}")

if __name__ == "__main__":
    main()
