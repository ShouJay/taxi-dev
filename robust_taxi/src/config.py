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

# MQTT 配置
MQTT_BROKER_HOST = os.getenv('MQTT_BROKER_HOST', 'localhost')
MQTT_BROKER_PORT = int(os.getenv('MQTT_BROKER_PORT', 1883))
MQTT_CLIENT_ID_PREFIX = os.getenv('MQTT_CLIENT_ID_PREFIX', 'robust-taxi')
MQTT_USERNAME = os.getenv('MQTT_USERNAME')
MQTT_PASSWORD = os.getenv('MQTT_PASSWORD')

# URL 配置
API_BASE_URL = os.getenv('API_BASE_URL', f'http://localhost:{FLASK_PORT}')
CDN_BASE_URL = os.getenv('CDN_BASE_URL', '').rstrip('/')

# 業務配置
DEFAULT_VIDEO = os.getenv('DEFAULT_VIDEO', 'default_ad_loop.mp4')

# 日誌配置
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')

