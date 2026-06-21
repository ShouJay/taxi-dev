"""MQTT Worker 啟動入口。"""

import logging

from src.mqtt_worker import MqttWorker


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
    worker = MqttWorker()
    worker.run_forever()

