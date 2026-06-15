#!/usr/bin/env python3
"""
簡單的 HTTP 服務器，用於提供管理面板
避免 file:// 協議的限制
"""

import http.server
import socketserver
import os
import webbrowser
from pathlib import Path

# 設置端口
PORT = 3001

class CustomHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # 添加 CORS 頭
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        super().end_headers()
    
    def do_OPTIONS(self):
        # 處理 CORS 預檢請求
        self.send_response(200)
        self.end_headers()

def main():
    # 確保在正確的目錄中
    os.chdir(Path(__file__).parent)
    
    # 檢查管理面板文件是否存在
    dashboard_file = Path("admin_dashboard.html")
    if not dashboard_file.exists():
        print(f"❌ 找不到管理面板文件: {dashboard_file}")
        return
    
    print(f"🚀 啟動管理面板服務器...")
    print(f"📁 服務目錄: {os.getcwd()}")
    print(f"🌐 服務地址: https://robusttaxi.azurewebsites.net")
    print(f"📊 管理面板: https://robusttaxi.azurewebsites.net/admin_dashboard.html")
    print(f"🔧 後端服務: https://robusttaxi.azurewebsites.net")
    print()
    
    try:
        with socketserver.TCPServer(("", PORT), CustomHTTPRequestHandler) as httpd:
            print(f"✅ 服務器已啟動，監聽端口 {PORT}")
            print("按 Ctrl+C 停止服務器")
            print()
            
            # 自動打開瀏覽器
            dashboard_url = "https://robusttaxi.azurewebsites.net/admin_dashboard.html"
            print(f"🌐 正在打開管理面板: {dashboard_url}")
            webbrowser.open(dashboard_url)
            
            httpd.serve_forever()
            
    except KeyboardInterrupt:
        print("\n👋 服務器已停止")
    except OSError as e:
        if e.errno == 48:  # Address already in use
            print(f"❌ 端口 {PORT} 已被佔用，請嘗試其他端口")
        else:
            print(f"❌ 啟動服務器失敗: {e}")

if __name__ == "__main__":
    main()
