#!/usr/bin/env python3
"""
App端分片下載功能測試腳本
模擬計程車設備接收下載命令並分片下載影片
"""

import socketio
import requests
import json
import os
import time
import math
from datetime import datetime

# 測試配置
SERVER_URL = "https://robusttaxi.azurewebsites.net"
WS_URL = "wss://robusttaxi.azurewebsites.net"
DEVICE_ID = "taxi-AAB-1234-rooftop"
CHUNK_SIZE = 5 * 1024 * 1024  # 5MB

class TaxiDeviceClient:
    """模擬計程車設備客戶端"""
    
    def __init__(self, device_id, server_url, ws_url):
        self.device_id = device_id
        self.server_url = server_url
        self.ws_url = ws_url
        self.sio = socketio.Client()
        self.download_folder = f"device_downloads/{device_id}"
        self.setup_event_handlers()
        
        # 確保下載文件夾存在
        os.makedirs(self.download_folder, exist_ok=True)
    
    def setup_event_handlers(self):
        """設置WebSocket事件處理器"""
        
        @self.sio.event
        def connect():
            print(f"✅ 設備 {self.device_id} 已連接到服務器")
            
        @self.sio.event
        def disconnect():
            print(f"❌ 設備 {self.device_id} 已斷開連接")
            
        @self.sio.event
        def connection_established(data):
            print(f"📡 連接建立: {data['message']}")
            
        @self.sio.event
        def registration_success(data):
            print(f"✅ 註冊成功: {data['message']}")
            
        @self.sio.event
        def registration_error(data):
            print(f"❌ 註冊失敗: {data['error']}")
            
        @self.sio.event
        def download_video(data):
            """處理下載命令"""
            print(f"\n🎬 收到下載命令:")
            print(f"   廣告ID: {data['advertisement_id']}")
            print(f"   廣告名稱: {data['advertisement_name']}")
            print(f"   文件大小: {self.format_file_size(data['file_size'])}")
            print(f"   下載模式: {data['download_mode']}")
            
            if data['download_mode'] == 'chunked':
                print(f"   分片大小: {self.format_file_size(data['chunk_size'])}")
                print(f"   總分片數: {data['total_chunks']}")
            
            # 開始下載
            self.download_video_chunked(data)
            
        @self.sio.event
        def download_status_ack(data):
            print(f"📊 下載狀態確認: {data['message']}")
            
        @self.sio.event
        def download_status_error(data):
            print(f"❌ 下載狀態錯誤: {data['error']}")
            
        @self.sio.event
        def download_request_error(data):
            print(f"❌ 下載請求錯誤: {data['error']}")
    
    def connect_and_register(self):
        """連接並註冊設備"""
        try:
            # 連接到WebSocket
            self.sio.connect(self.ws_url)
            
            # 註冊設備
            self.sio.emit('register', {
                'device_id': self.device_id
            })
            
            time.sleep(1)  # 等待註冊完成
            
        except Exception as e:
            print(f"❌ 連接失敗: {e}")
            return False
        
        return True
    
    def download_video_chunked(self, download_command):
        """分片下載影片"""
        advertisement_id = download_command['advertisement_id']
        file_size = download_command['file_size']
        chunk_size = download_command['chunk_size']
        total_chunks = download_command['total_chunks']
        
        print(f"\n📥 開始分片下載: {advertisement_id}")
        
        try:
            # 發送下載開始狀態
            self.sio.emit('download_status', {
                'device_id': self.device_id,
                'advertisement_id': advertisement_id,
                'status': 'downloading',
                'progress': 0,
                'total_chunks': total_chunks
            })
            
            downloaded_data = b""
            downloaded_chunks = []
            
            # 下載每個分片
            for chunk_number in range(total_chunks):
                print(f"   下載分片 {chunk_number + 1}/{total_chunks}...", end=" ")
                
                # 下載分片
                chunk_url = f"{self.server_url}/api/v1/device/videos/{advertisement_id}/chunk"
                params = {
                    'chunk': chunk_number,
                    'chunk_size': chunk_size
                }
                
                response = requests.get(chunk_url, params=params)
                
                if response.status_code == 200:
                    chunk_data = response.content
                    downloaded_data += chunk_data
                    downloaded_chunks.append(chunk_number)
                    
                    # 計算進度
                    progress = int(((chunk_number + 1) / total_chunks) * 100)
                    
                    print(f"✅ ({self.format_file_size(len(chunk_data))})")
                    
                    # 發送進度更新
                    self.sio.emit('download_status', {
                        'device_id': self.device_id,
                        'advertisement_id': advertisement_id,
                        'status': 'downloading',
                        'progress': progress,
                        'downloaded_chunks': downloaded_chunks,
                        'total_chunks': total_chunks
                    })
                    
                    # 模擬下載延遲
                    time.sleep(0.1)
                else:
                    print(f"❌ 失敗: {response.status_code}")
                    raise Exception(f"分片 {chunk_number} 下載失敗")
            
            # 保存文件
            filename = download_command['video_filename']
            file_path = os.path.join(self.download_folder, filename)
            
            with open(file_path, 'wb') as f:
                f.write(downloaded_data)
            
            # 驗證文件大小
            actual_size = len(downloaded_data)
            if actual_size == file_size:
                print(f"✅ 下載完成: {filename} ({self.format_file_size(actual_size)})")
                
                # 發送完成狀態
                self.sio.emit('download_status', {
                    'device_id': self.device_id,
                    'advertisement_id': advertisement_id,
                    'status': 'completed',
                    'progress': 100,
                    'downloaded_chunks': downloaded_chunks,
                    'total_chunks': total_chunks
                })
            else:
                print(f"❌ 文件大小不匹配: 期望 {file_size}, 實際 {actual_size}")
                raise Exception("文件大小驗證失敗")
                
        except Exception as e:
            print(f"❌ 下載失敗: {e}")
            
            # 發送失敗狀態
            self.sio.emit('download_status', {
                'device_id': self.device_id,
                'advertisement_id': advertisement_id,
                'status': 'failed',
                'progress': 0,
                'error_message': str(e)
            })
    
    def request_download(self, advertisement_id, download_mode='chunked'):
        """主動請求下載廣告"""
        print(f"\n📤 請求下載廣告: {advertisement_id}")
        
        self.sio.emit('download_request', {
            'device_id': self.device_id,
            'advertisement_id': advertisement_id,
            'download_mode': download_mode
        })
    
    def send_heartbeat(self):
        """發送心跳"""
        self.sio.emit('heartbeat', {
            'device_id': self.device_id
        })
    
    def disconnect(self):
        """斷開連接"""
        self.sio.disconnect()
    
    def format_file_size(self, size_bytes):
        """格式化文件大小"""
        if size_bytes == 0:
            return "0 Bytes"
        size_names = ["Bytes", "KB", "MB", "GB"]
        i = int(math.floor(math.log(size_bytes, 1024)))
        p = math.pow(1024, i)
        s = round(size_bytes / p, 2)
        return f"{s} {size_names[i]}"


def test_push_download():
    """測試推送下載功能"""
    print("=== 測試推送下載功能 ===")
    
    # 創建設備客戶端
    device = TaxiDeviceClient(DEVICE_ID, SERVER_URL, WS_URL)
    
    try:
        # 連接並註冊
        if not device.connect_and_register():
            return False
        
        print(f"\n⏳ 等待下載命令...")
        print("請在管理後台發送推送下載命令")
        
        # 保持連接，等待下載命令
        while True:
            device.send_heartbeat()
            time.sleep(10)  # 每10秒發送一次心跳
            
    except KeyboardInterrupt:
        print("\n🛑 測試中斷")
    except Exception as e:
        print(f"❌ 測試出錯: {e}")
    finally:
        device.disconnect()
    
    return True


def test_request_download():
    """測試主動請求下載"""
    print("\n=== 測試主動請求下載 ===")
    
    # 創建設備客戶端
    device = TaxiDeviceClient(DEVICE_ID, SERVER_URL, WS_URL)
    
    try:
        # 連接並註冊
        if not device.connect_and_register():
            return False
        
        # 主動請求下載（需要先有廣告存在）
        advertisement_id = "test-chunked-10mb"  # 假設這個廣告存在
        device.request_download(advertisement_id)
        
        # 等待下載完成
        time.sleep(30)
        
    except KeyboardInterrupt:
        print("\n🛑 測試中斷")
    except Exception as e:
        print(f"❌ 測試出錯: {e}")
    finally:
        device.disconnect()
    
    return True


def test_health_check():
    """測試服務器健康狀態"""
    print("=== 測試服務器健康狀態 ===")
    
    try:
        response = requests.get(f"{SERVER_URL}/health")
        
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
    print("開始App端分片下載功能測試...")
    print(f"服務器: {SERVER_URL}")
    print(f"設備ID: {DEVICE_ID}")
    
    # 測試服務器健康狀態
    if not test_health_check():
        print("❌ 服務器不可用，請確保服務器正在運行")
        return
    
    # 選擇測試模式
    print("\n請選擇測試模式:")
    print("1. 等待推送下載命令")
    print("2. 主動請求下載")
    print("3. 退出")
    
    try:
        choice = input("請輸入選擇 (1-3): ").strip()
        
        if choice == "1":
            test_push_download()
        elif choice == "2":
            test_request_download()
        elif choice == "3":
            print("👋 測試結束")
        else:
            print("❌ 無效選擇")
            
    except KeyboardInterrupt:
        print("\n👋 測試結束")
    except Exception as e:
        print(f"❌ 測試出錯: {e}")


if __name__ == "__main__":
    main()
