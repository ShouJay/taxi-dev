"""MQTT 發布器封裝。"""

import json
import logging
import threading
import uuid

import paho.mqtt.client as mqtt

from src.config import (
    MQTT_BROKER_HOST,
    MQTT_BROKER_PORT,
    MQTT_CLIENT_ID_PREFIX,
    MQTT_PASSWORD,
    MQTT_USERNAME,
)

logger = logging.getLogger(__name__)


class MqttPublisher:
    """Thread-safe MQTT 發布器。"""

    def __init__(self, client_id_suffix="publisher"):
        client_id = f"{MQTT_CLIENT_ID_PREFIX}-{client_id_suffix}-{uuid.uuid4().hex[:8]}"
        self._client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)
        self._connected = False
        self._lock = threading.Lock()

        if MQTT_USERNAME:
            self._client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)

        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect

    def _on_connect(self, _client, _userdata, _flags, rc):
        self._connected = rc == 0
        if self._connected:
            logger.info("MQTT publisher connected")
        else:
            logger.error(f"MQTT publisher connect failed: rc={rc}")

    def _on_disconnect(self, _client, _userdata, _rc):
        self._connected = False
        logger.warning("MQTT publisher disconnected")

    def connect(self):
        with self._lock:
            if self._connected:
                return
            try:
                self._client.connect(MQTT_BROKER_HOST, MQTT_BROKER_PORT, keepalive=60)
                self._client.loop_start()
            except Exception as exc:
                self._connected = False
                logger.warning(f"MQTT publisher connect failed: {exc}")

    def disconnect(self):
        with self._lock:
            self._client.loop_stop()
            self._client.disconnect()
            self._connected = False

    def is_connected(self):
        return self._connected

    def publish(self, topic, payload, qos=1, retain=False):
        if not self._connected:
            self.connect()
        if not self._connected:
            logger.warning(f"Skip publish to {topic}: MQTT not connected")
            return False
        body = json.dumps(payload, ensure_ascii=False)
        info = self._client.publish(topic, body, qos=qos, retain=retain)
        info.wait_for_publish(timeout=5)
        return info.rc == mqtt.MQTT_ERR_SUCCESS

    def publish_desired(self, device_id, payload):
        topic = f"taxi/{device_id}/playlist/desired"
        return self.publish(topic, payload, qos=1, retain=True)

    def publish_emergency(self, payload):
        return self.publish("taxi/all/emergency", payload, qos=1, retain=True)


_publisher_instance = None
_instance_lock = threading.Lock()


def get_mqtt_publisher():
    global _publisher_instance
    with _instance_lock:
        if _publisher_instance is None:
            _publisher_instance = MqttPublisher()
            _publisher_instance.connect()
    return _publisher_instance

