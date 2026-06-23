import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../config/app_config.dart';
import '../services/mqtt_manager.dart';
import '../managers/playback_manager.dart';
import '../services/download_manager.dart';
import '../services/location_service.dart';
import '../models/download_info.dart';

class SettingsScreen extends StatefulWidget {
  final MqttManager mqttManager;
  final PlaybackManager playbackManager;
  final DownloadManager downloadManager;
  final LocationService? locationService;
  final bool isAdminMode;
  final String deviceRole;
  final Future<void> Function(bool) onAdminModeChanged;
  final Future<void> Function(String) onDeviceRoleChanged;
  final VoidCallback onBack;

  const SettingsScreen({
    super.key,
    required this.mqttManager,
    required this.playbackManager,
    required this.downloadManager,
    this.locationService,
    required this.isAdminMode,
    required this.deviceRole,
    required this.onAdminModeChanged,
    required this.onDeviceRoleChanged,
    required this.onBack,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _deviceIdController;
  late TextEditingController _brokerHostController;
  String _connectionStatus = '檢查中...';
  String _lastUpdate = '---';
  bool _isSaving = false;
  late bool _isAdminMode;
  late String _deviceRole;
  bool _isUpdatingAdminMode = false;

  Map<String, DownloadTask> _activeDownloads = {};
  Timer? _downloadMonitoringTimer;

  @override
  void initState() {
    super.initState();
    _deviceIdController = TextEditingController(text: widget.mqttManager.deviceId);
    _brokerHostController = TextEditingController(
      text: widget.mqttManager.brokerHost,
    );
    _isAdminMode = widget.isAdminMode;
    _deviceRole = widget.deviceRole;
    _updateConnectionStatus();
    _startStatusMonitoring();
    _startDownloadMonitoring();
  }

  void _startDownloadMonitoring() {
    _downloadMonitoringTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final activeDownloads = widget.downloadManager.getActiveDownloads();
        setState(() {
          _activeDownloads = {
            for (var task in activeDownloads) task.advertisementId: task,
          };
        });
      },
    );
  }

  void _updateConnectionStatus() {
    setState(() {
      _connectionStatus = widget.mqttManager.isConnected
          ? '✅ MQTT 已連接'
          : '❌ MQTT 未連接';
      _lastUpdate = DateTime.now().toString().substring(0, 19);
    });
  }

  void _startStatusMonitoring() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        _updateConnectionStatus();
        return true;
      }
      return false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = widget.mqttManager.isConnected;
    final connectionIcon = isConnected ? Icons.cloud_done : Icons.cloud_off;
    final connectionColor = isConnected ? Colors.green : Colors.red;

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('設備設定'),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _deviceIdController,
              label: '設備 ID',
              hint: '例如: taxi-AAB-1234-rooftop',
              icon: Icons.devices,
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _brokerHostController,
              label: 'MQTT Broker 位址',
              hint: '例如: 10.0.2.2 或 192.168.x.x',
              icon: Icons.hub,
            ),
            const SizedBox(height: 16),
            _buildDeviceRoleSelector(),
            const SizedBox(height: 24),
            _buildAdminModeTile(),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _saveSettings,
                icon: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_isSaving ? '儲存中...' : '儲存設定'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 32),
            _buildSectionTitle('通訊狀況 (MQTT)'),
            const SizedBox(height: 16),
            _buildStatusCard(
              title: 'MQTT 連線',
              value: _connectionStatus,
              icon: connectionIcon,
              color: connectionColor,
            ),
            const SizedBox(height: 12),
            _buildStatusCard(
              title: 'Broker',
              value: '${widget.mqttManager.brokerHost}:${AppConfig.mqttBrokerPort}',
              icon: Icons.dns,
              color: Colors.blue,
            ),
            const SizedBox(height: 12),
            _buildStatusCard(
              title: '最後更新',
              value: _lastUpdate,
              icon: Icons.access_time,
              color: Colors.blue,
            ),
            const SizedBox(height: 12),
            _buildStatusCard(
              title: '播放狀態',
              value: _getPlaybackStateText(),
              icon: Icons.play_circle,
              color: Colors.orange,
            ),
            if (widget.locationService != null) ...[
              const SizedBox(height: 12),
              _buildStatusCard(
                title: 'GPS 位置狀態',
                value: widget.locationService!.getLocationAckStatus(),
                icon: Icons.location_on,
                color: Colors.green,
              ),
              const SizedBox(height: 12),
              _buildStatusCard(
                title: '位置上報次數',
                value: '${widget.locationService!.sentCount}',
                icon: Icons.analytics,
                color: Colors.blue,
              ),
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 32),
            _buildSectionTitle('下載進度'),
            const SizedBox(height: 16),
            _buildDownloadProgressSection(),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 32),
            _buildSectionTitle('播放列表'),
            const SizedBox(height: 16),
            _buildPlaylistSection(),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 32),
            _buildSectionTitle('操作'),
            const SizedBox(height: 16),
            _buildActionButton(
              label: '測試播放',
              icon: Icons.play_arrow,
              onPressed: _testPlayDefaultVideo,
            ),
            const SizedBox(height: 12),
            _buildActionButton(
              label: '重新連接 MQTT',
              icon: Icons.refresh,
              onPressed: _reconnect,
            ),
            const SizedBox(height: 32),
            Center(
              child: Text(
                'Taxi App v2.0.0 (MQTT)',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceRoleSelector() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '設備角色',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.tv),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _deviceRole,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: 'SCREEN_A', child: Text('SCREEN_A — 廣告屏（跑馬燈）')),
            DropdownMenuItem(value: 'SCREEN_B', child: Text('SCREEN_B — 互動屏（QR / 警報）')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _deviceRole = value);
          },
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildStatusCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminModeTile() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: SwitchListTile(
        title: const Text('管理員模式', style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          '開啟後於播放畫面顯示調試資訊',
          style: TextStyle(color: Colors.grey[600]),
        ),
        value: _isAdminMode,
        onChanged: _isUpdatingAdminMode ? null : _handleAdminModeChanged,
        secondary: Icon(
          _isAdminMode ? Icons.admin_panel_settings : Icons.visibility_off,
          color: _isAdminMode ? Colors.blue : Colors.grey,
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: color),
        label: Text(label, style: TextStyle(color: color)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: color ?? Colors.blue),
        ),
      ),
    );
  }

  String _getPlaybackStateText() {
    switch (widget.playbackManager.state) {
      case PlaybackState.idle:
        return '閒置';
      case PlaybackState.loading:
        return '載入中';
      case PlaybackState.playing:
        return '播放中';
      case PlaybackState.paused:
        return '已暫停';
      case PlaybackState.error:
        return '錯誤';
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    try {
      final newDeviceId = _deviceIdController.text.trim();
      final newBrokerHost = _brokerHostController.text.trim();

      if (newDeviceId.isEmpty || newBrokerHost.isEmpty) {
        _showMessage('設備 ID 與 Broker 位址不可為空');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfig.deviceIdKey, newDeviceId);
      await prefs.setString(AppConfig.mqttBrokerHostKey, newBrokerHost);
      await widget.onDeviceRoleChanged(_deviceRole);

      await widget.mqttManager.updateBrokerHost(newBrokerHost);
      await widget.mqttManager.updateDeviceId(newDeviceId);

      _showMessage('設定已儲存');
    } catch (e) {
      _showMessage('儲存失敗: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _testPlayDefaultVideo() async {
    await widget.playbackManager.startAutoPlay();
    _showMessage('開始播放本地影片');
  }

  void _reconnect() {
    widget.mqttManager.disconnect();
    Future.delayed(const Duration(seconds: 1), () {
      widget.mqttManager.connect();
      _showMessage('正在重新連接 MQTT...');
    });
  }

  Future<void> _handleAdminModeChanged(bool value) async {
    setState(() => _isUpdatingAdminMode = true);
    try {
      await widget.onAdminModeChanged(value);
      setState(() => _isAdminMode = value);
    } finally {
      if (mounted) setState(() => _isUpdatingAdminMode = false);
    }
  }

  Widget _buildPlaylistSection() {
    final playlist = widget.playbackManager.getFullPlaylist();
    final systemPlaylist = playlist.where((item) => !item.isLocalVideo).toList();
    final localPlaylist = playlist.where((item) => item.isLocalVideo).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPlaylistGroup(
          title: '播放清單（系統）',
          emptyHint: '目前沒有活動或排程中的影片',
          items: systemPlaylist,
        ),
        const SizedBox(height: 24),
        _buildPlaylistGroup(
          title: '本地影片清單',
          emptyHint: '尚未匯入本地影片',
          items: localPlaylist,
        ),
      ],
    );
  }

  Widget _buildPlaylistGroup({
    required String title,
    required String emptyHint,
    required List<PlaybackInfo> items,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (items.isEmpty)
          _buildEmptyPlaylistCard(emptyHint)
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _buildPlaylistItem(items[index]),
          ),
      ],
    );
  }

  Widget _buildEmptyPlaylistCard(String hint) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(hint, style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
    );
  }

  Widget _buildPlaylistItem(PlaybackInfo item) {
    return Card(
      child: ListTile(
        leading: Icon(
          item.isCurrentPlaying ? Icons.play_circle_filled : Icons.video_library,
          color: item.isCurrentPlaying ? Colors.green : Colors.blue,
        ),
        title: Text(item.title),
        subtitle: Text(item.filename, style: const TextStyle(fontSize: 12)),
        trailing: item.isLocalVideo
            ? IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () => _confirmDeleteVideo(item),
              )
            : null,
      ),
    );
  }

  Future<void> _confirmDeleteVideo(PlaybackInfo item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認刪除'),
        content: Text('確定要刪除 "${item.filename}" 嗎？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await widget.playbackManager.deleteVideo(item.filename);
      _showMessage(success ? '已刪除' : '刪除失敗');
      if (mounted) setState(() {});
    }
  }

  Widget _buildDownloadProgressSection() {
    if (_activeDownloads.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          '目前沒有進行中的下載任務',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      children: _activeDownloads.values.map((task) {
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.downloadInfo.filename, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: task.progress / 100),
              Text('${task.progress}%'),
            ],
          ),
        );
      }).toList(),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _downloadMonitoringTimer?.cancel();
    _deviceIdController.dispose();
    _brokerHostController.dispose();
    super.dispose();
  }
}
