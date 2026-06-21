"""MQTT 訂閱 Worker。"""

import json
import logging
import uuid
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

from src.config import (
    DATABASE_NAME,
    MONGODB_URI,
    MQTT_BROKER_HOST,
    MQTT_BROKER_PORT,
    MQTT_CLIENT_ID_PREFIX,
    MQTT_PASSWORD,
    MQTT_USERNAME,
)
from src.database import Database
from src.mqtt_client import MqttPublisher
from src.services import AdDecisionService

logger = logging.getLogger(__name__)


class MqttWorker:
    def __init__(self):
        self.db = Database(MONGODB_URI, DATABASE_NAME)
        self.ad_service = AdDecisionService(self.db)
        self.publisher = MqttPublisher(client_id_suffix="worker-pub")
        self.publisher.connect()

        client_id = f"{MQTT_CLIENT_ID_PREFIX}-worker-sub-{uuid.uuid4().hex[:8]}"
        self.client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)
        if MQTT_USERNAME:
            self.client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message

    def _on_connect(self, client, _userdata, _flags, rc):
        if rc != 0:
            logger.error(f"MQTT worker connect failed: rc={rc}")
            return
        logger.info("MQTT worker connected")
        client.subscribe("taxi/+/location", qos=0)
        client.subscribe("taxi/+/playlist/reported", qos=1)
        client.subscribe("taxi/+/status", qos=1)

    @staticmethod
    def _device_id_from_topic(topic):
        parts = topic.split("/")
        if len(parts) < 3:
            return None
        return parts[1]

    def _on_message(self, _client, _userdata, message):
        try:
            payload = json.loads(message.payload.decode("utf-8"))
        except json.JSONDecodeError:
            logger.warning(f"無法解析 MQTT payload: {message.topic}")
            return

        try:
            if message.topic.endswith("/location"):
                self._handle_location(message.topic, payload)
            elif message.topic.endswith("/playlist/reported"):
                self._handle_reported(message.topic, payload)
            elif message.topic.endswith("/status"):
                self._handle_status(message.topic, payload)
        except Exception as exc:
            logger.error(f"處理 MQTT 訊息失敗 topic={message.topic}: {exc}", exc_info=True)

    def _handle_location(self, topic, payload):
        device_id = self._device_id_from_topic(topic)
        if not device_id:
            return

        lat = payload.get("lat")
        lng = payload.get("lng")
        if lat is None or lng is None:
            logger.warning(f"location payload 缺少 lat/lng: {payload}")
            return

        desired = self.ad_service.build_desired_playlist(device_id, lng, lat)
        if desired is None:
            logger.warning(f"設備不存在，略過 desired 發布: {device_id}")
            return

        existing = self.db.devices.find_one({"_id": device_id}) or {}
        current_desired = (
            existing.get("shadow", {}).get("desired")
            if isinstance(existing.get("shadow"), dict)
            else None
        )
        if current_desired == desired:
            return

        self.db.devices.update_one(
            {"_id": device_id},
            {
                "$set": {
                    "status": "online",
                    "shadow.desired": desired,
                }
            },
            upsert=False,
        )
        self.publisher.publish_desired(device_id, desired)

    def _handle_reported(self, topic, payload):
        device_id = self._device_id_from_topic(topic)
        if not device_id:
            return

        reported_payload = {
            "current_campaign_id": payload.get("current_campaign_id"),
            "local_inventory": payload.get("local_inventory", []),
            "errors": payload.get("errors", []),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        self.db.devices.update_one(
            {"_id": device_id},
            {"$set": {"shadow.reported": reported_payload, "status": "online"}},
            upsert=False,
        )

    def _handle_status(self, topic, payload):
        device_id = self._device_id_from_topic(topic)
        if not device_id:
            return
        status = payload.get("status", "offline")
        normalized = "online" if status == "online" else "offline"
        self.db.devices.update_one(
            {"_id": device_id},
            {"$set": {"status": normalized}},
            upsert=False,
        )

    def run_forever(self):
        self.client.connect(MQTT_BROKER_HOST, MQTT_BROKER_PORT, keepalive=60)
        self.client.loop_forever()

