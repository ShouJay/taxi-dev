"""
配置文件
存儲所有應用程序配置參數
"""

import os

# MongoDB 連接配置
MONGODB_URI = os.getenv('MONGODB_URI', 'mongodb+srv://taxi_user:taxi@taxidb.ed4tqft.mongodb.net/?appName=TaxiDB')
DATABASE_NAME = os.getenv('DATABASE_NAME', 'smart_taxi_ads')

# Flask 配置
# FLASK_HOST = os.getenv('FLASK_HOST', '0.0.0.0')
# FLASK_PORT = int(os.getenv('FLASK_PORT', 8080))
FLASK_HOST = '0.0.0.0'
FLASK_PORT = 8080
FLASK_DEBUG = os.getenv('FLASK_DEBUG', 'True').lower() == 'true'

# 業務配置
DEFAULT_VIDEO = os.getenv('DEFAULT_VIDEO', 'default_ad_loop.mp4')

# 日誌配置
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')

