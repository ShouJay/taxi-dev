"""
整合版智能計程車廣告服務啟動腳本
結合廣告決策和實時推送功能

使用方式:
1. 啟動服務: python run_integrated.py
2. 初始化數據庫: curl http://localhost:8080/init_db
3. 使用 WebSocket 客戶端連接並發送位置數據
"""

import os
import sys
import logging

# 添加 src 目錄到 Python 路徑
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

# 導入並運行整合應用
if __name__ == '__main__':
    from src.app import app, socketio, FLASK_HOST, FLASK_PORT, FLASK_DEBUG
    
    # 配置日誌
    logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
    logger = logging.getLogger(__name__)

    try:
        logger.info(f"正在啟動整合版智能計程車廣告服務...")
        logger.info(f"WebSocket 端點: ws://{FLASK_HOST}:{FLASK_PORT}")
        logger.info(f"HTTP 端點: http://{FLASK_HOST}:{FLASK_PORT}")
        logger.info("請先訪問 http://{}/init_db 來初始化數據庫".format(f"{FLASK_HOST}:{FLASK_PORT}"))
        
        # 運行整合應用程序
        socketio.run(
            app,
            host=FLASK_HOST,
            port=FLASK_PORT,
            debug=FLASK_DEBUG,
            allow_unsafe_werkzeug=True
        )
    except Exception as e:
        logger.error(f"啟動整合服務失敗: {e}")
