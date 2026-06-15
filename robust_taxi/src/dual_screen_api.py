from flask import Blueprint, jsonify, request
from src.emergency_manager import EmergencyManager
import logging

dual_screen_bp = Blueprint('dual_screen_bp', __name__, url_prefix='/api/v2')
logger = logging.getLogger(__name__)
manager = EmergencyManager()

@dual_screen_bp.route('/control/status', methods=['GET'])
def get_status():
    """Get current system status (Normal/Alarm) and config"""
    return jsonify(manager.get_state())

@dual_screen_bp.route('/control/trigger', methods=['POST'])
def trigger_alarm():
    """Trigger the Emergency Alarm"""
    manager.trigger_alarm()
    return jsonify({
        "status": "success", 
        "message": "Alarm triggered", 
        "state": manager.get_state()
    })

@dual_screen_bp.route('/control/reset', methods=['POST'])
def reset_alarm():
    """Reset to Normal Mode"""
    manager.reset_alarm()
    return jsonify({
        "status": "success", 
        "message": "Alarm reset", 
        "state": manager.get_state()
    })

@dual_screen_bp.route('/config/marquee', methods=['POST'])
def set_marquee():
    """Set the marquee text"""
    data = request.get_json()
    text = data.get('text')
    if not text:
        return jsonify({"status": "error", "message": "Text required"}), 400
    
    manager.set_marquee(text)
    return jsonify({
        "status": "success", 
        "message": "Marquee updated",
        "text": text
    })

@dual_screen_bp.route('/config/video', methods=['POST'])
def set_emergency_video():
    """Set the emergency video filename"""
    data = request.get_json()
    filename = data.get('filename')
    if not filename:
        return jsonify({"status": "error", "message": "Filename required"}), 400
    
    manager.set_emergency_video(filename)
    return jsonify({
        "status": "success", 
        "message": "Emergency video updated",
        "filename": filename
    })

@dual_screen_bp.route('/stats/qr', methods=['GET'])
def get_qr_stats():
    """Get current QR scan count"""
    return jsonify({
        "count": manager.qr_scan_count
    })

@dual_screen_bp.route('/stats/qr', methods=['POST'])
def record_qr_scan_v2():
    """
    Record a QR scan (V2) - increments counter and notifies apps.
    Designed to be called by the frontend.
    """
    count = manager.increment_qr_count()
    return jsonify({
        "status": "success",
        "count": count
    })
