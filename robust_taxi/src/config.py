"""
配置文件
存儲所有應用程序配置參數
"""

import os

# 運行環境
APP_ENV = os.getenv('APP_ENV', 'development').lower()
if APP_ENV == 'azure':
    APP_ENV = 'production'
if APP_ENV not in {'development', 'staging', 'production'}:
    raise RuntimeError(f'不支援的 APP_ENV: {APP_ENV}')

# MongoDB 連接配置
MONGODB_URI = os.getenv('MONGODB_URI', 'mongodb://localhost:27017/')
DATABASE_NAME = os.getenv('DATABASE_NAME', 'smart_taxi_ads')

# Flask 配置
FLASK_HOST = os.getenv('FLASK_HOST', '0.0.0.0')
FLASK_PORT = int(os.getenv('FLASK_PORT', 8080))
FLASK_DEBUG = os.getenv('FLASK_DEBUG', 'True').lower() == 'true'
SECRET_KEY = os.getenv('SECRET_KEY', 'development-only-secret-key')

if APP_ENV in {'staging', 'production'} and SECRET_KEY == 'development-only-secret-key':
    raise RuntimeError(f'{APP_ENV} 環境必須設定 SECRET_KEY')

# MQTT 配置
MQTT_BROKER_HOST = os.getenv('MQTT_BROKER_HOST', 'localhost')
MQTT_BROKER_PORT = int(os.getenv('MQTT_BROKER_PORT', 1883))
MQTT_CLIENT_ID_PREFIX = os.getenv('MQTT_CLIENT_ID_PREFIX', 'robust-taxi')
MQTT_USERNAME = os.getenv('MQTT_USERNAME')
MQTT_PASSWORD = os.getenv('MQTT_PASSWORD')

# URL 配置
API_BASE_URL = os.getenv('API_BASE_URL', f'http://localhost:{FLASK_PORT}')
CDN_BASE_URL = os.getenv('CDN_BASE_URL', '').rstrip('/')

# 影片儲存配置
UPLOAD_ROOT = os.getenv('UPLOAD_ROOT', 'uploads')

# 業務配置
DEFAULT_VIDEO = os.getenv('DEFAULT_VIDEO', 'default_ad_loop.mp4')

# 日誌配置
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')

if APP_ENV in {'staging', 'production'}:
    required_settings = (
        'MONGODB_URI',
        'SECRET_KEY',
        'MQTT_BROKER_HOST',
        'MQTT_USERNAME',
        'MQTT_PASSWORD',
        'API_BASE_URL',
    )
    missing_settings = [name for name in required_settings if not os.getenv(name)]
    if missing_settings:
        raise RuntimeError(
            f'{APP_ENV} 環境缺少必要設定: {", ".join(missing_settings)}'
        )
