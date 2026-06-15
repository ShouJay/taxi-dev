import logging
from datetime import datetime

logger = logging.getLogger(__name__)

class EmergencyManager:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(EmergencyManager, cls).__new__(cls)
            cls._instance.initialize()
        return cls._instance

    def initialize(self):
        self.is_alarm_active = False
        self.marquee_text = "地震速報：請保持冷靜，尋找掩護。"
        # 預設警報影片檔名，App 應預先下載此影片以達成秒級切換
        self.emergency_video_filename = "earthquake_alert.mp4" 
        self.qr_scan_count = 0
        self.socketio = None
        logger.info("EmergencyManager initialized")

    def set_socketio(self, socketio):
        self.socketio = socketio

    def trigger_alarm(self):
        if not self.is_alarm_active:
            self.is_alarm_active = True
            self.broadcast_state()
            logger.info("🚨 ALARM TRIGGERED 🚨")
            return True
        return False

    def reset_alarm(self):
        if self.is_alarm_active:
            self.is_alarm_active = False
            self.broadcast_state()
            logger.info(" ALARM RESET (Back to Normal)")
            return True
        return False

    def set_marquee(self, text):
        self.marquee_text = text
        # If we are in alarm mode (or if marquee is always shown), broadcast update
        self.broadcast_state()

    def set_emergency_video(self, filename):
        self.emergency_video_filename = filename
        self.broadcast_state()
        logger.info(f"Emergency video updated to: {filename}")

    def increment_qr_count(self):
        self.qr_scan_count += 1
        self.broadcast_stats()
        return self.qr_scan_count

    def get_state(self):
        return {
            "is_alarm_active": self.is_alarm_active,
            "marquee_text": self.marquee_text,
            "emergency_video": self.emergency_video_filename,
            "timestamp": datetime.now().isoformat()
        }

    def broadcast_state(self):
        if self.socketio:
            self.socketio.emit('system_state_update', self.get_state())

    def broadcast_stats(self):
        if self.socketio:
            self.socketio.emit('stats_update', {
                "qr_scan_count": self.qr_scan_count,
                "timestamp": datetime.now().isoformat()
            })
