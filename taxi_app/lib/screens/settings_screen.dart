import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../config/app_config.dart';
import '../services/mqtt_manager.dart';
import '../managers/playback_manager.dart';
import '../services/download_manager.dart';
import '../services/location_service.dart';

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
  late TextEditingController _apiServerUrlController;
  
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
    _deviceIdController = TextEditingController(
      text: widget.mqttManager.deviceId,
    );
    _brokerHostController = TextEditingController(
      text: widget.mqttManager.brokerHost,
    );
    _apiServerUrlController = TextEditingController(
      text: widget.downloadManager.baseUrl,
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
          ? '✅ 已連線'
          : '❌ 未連線';
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
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('設定'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDeviceConfigSection(),
            const SizedBox(height: 16),
            _buildStatusSection(),
            const SizedBox(height: 16),
            _buildDownloadsSection(),
            const SizedBox(height: 16),
            _buildPlaylistSection(),
            const SizedBox(height: 16),
            _buildActionsSection(),
            const SizedBox(height: 32),
            Center(
              child: Text(
                'Taxi App v2.0.0 (MQTT)',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        children: [
          Icon(icon, color: Colors.blue),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceConfigSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('系統與連線設定', Icons.settings),
            const SizedBox(height: 8),
            TextField(
              controller: _deviceIdController,
              decoration: const InputDecoration(
                labelText: '設備 ID',
                prefixIcon: Icon(Icons.devices),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _brokerHostController,
              decoration: const InputDecoration(
                labelText: 'MQTT Broker 位址',
                prefixIcon: Icon(Icons.hub),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiServerUrlController,
              decoration: const InputDecoration(
                labelText: 'API 伺服器 URL',
                hintText: '例如: http://192.168.0.103:8080/api/v1',
                prefixIcon: Icon(Icons.cloud),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _deviceRole,
              decoration: const InputDecoration(
                labelText: '設備角色',
                prefixIcon: Icon(Icons.tv),
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'SCREEN_A', child: Text('SCREEN_A — 廣告屏')),
                DropdownMenuItem(value: 'SCREEN_B', child: Text('SCREEN_B — 互動屏')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _deviceRole = value);
              },
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('管理員模式'),
              subtitle: const Text('開啟後顯示詳細調試資訊'),
              value: _isAdminMode,
              onChanged: _isUpdatingAdminMode ? null : _handleAdminModeChanged,
              secondary: Icon(
                _isAdminMode ? Icons.admin_panel_settings : Icons.visibility_off,
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _saveSettings,
                icon: _isSaving 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
                label: Text(_isSaving ? '儲存中...' : '儲存設定'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSection() {
    final isConnected = widget.mqttManager.isConnected;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('系統狀態', Icons.monitor_heart),
            ListTile(
              leading: Icon(
                isConnected ? Icons.cloud_done : Icons.cloud_off, 
                color: isConnected ? Colors.green : Colors.red,
                size: 32,
              ),
              title: const Text('MQTT 連線狀態'),
              subtitle: Text(
                _connectionStatus,
                style: TextStyle(
                  color: isConnected ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              contentPadding: EdgeInsets.zero,
            ),
            const Divider(),
            _buildInfoRow('播放狀態', _getPlaybackStateText(), Icons.play_circle),
            _buildInfoRow('最後更新', _lastUpdate, Icons.access_time),
            if (widget.locationService != null) ...[
              _buildInfoRow('GPS 狀態', widget.locationService!.getLocationAckStatus(), Icons.location_on),
              _buildInfoRow('上報次數', '${widget.locationService!.sentCount}', Icons.analytics),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: Colors.grey[700])),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDownloadsSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('下載進度', Icons.downloading),
            if (_activeDownloads.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16.0),
                child: Center(child: Text('目前沒有下載任務', style: TextStyle(color: Colors.grey))),
              )
            else
              ..._activeDownloads.values.map((task) => Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            task.downloadInfo.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Text('${task.progress}%'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: task.progress / 100),
                  ],
                ),
              )),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistSection() {
    final playlist = widget.playbackManager.getFullPlaylist();
    final systemPlaylist = playlist.where((item) => !item.isLocalVideo).toList();
    final localPlaylist = playlist.where((item) => item.isLocalVideo).toList();

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('播放列表', Icons.video_library),
            const Text('系統影片', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (systemPlaylist.isEmpty)
              const Text('無系統排程影片', style: TextStyle(color: Colors.grey))
            else
              ...systemPlaylist.map((item) => _buildPlaylistItem(item)),
            
            const Divider(height: 32),
            const Text('本地預設影片', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (localPlaylist.isEmpty)
              const Text('無本地影片', style: TextStyle(color: Colors.grey))
            else
              ...localPlaylist.map((item) => _buildPlaylistItem(item)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistItem(PlaybackInfo item) {
    final isPlaying = item.isCurrentPlaying;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isPlaying ? Icons.play_arrow : Icons.movie,
        color: isPlaying ? Colors.green : Colors.blue,
      ),
      title: Text(
        item.title,
        style: TextStyle(
          fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
          color: isPlaying ? Colors.green : Colors.black87,
        ),
      ),
      subtitle: Text(item.filename),
      trailing: item.isLocalVideo
          ? IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () => _confirmDeleteVideo(item),
            )
          : null,
    );
  }

  Widget _buildActionsSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('系統操作', Icons.build),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _testPlayDefaultVideo,
                icon: const Icon(Icons.play_arrow),
                label: const Text('測試播放本地影片'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _reconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('重新連接 MQTT'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getPlaybackStateText() {
    switch (widget.playbackManager.state) {
      case PlaybackState.idle: return '閒置';
      case PlaybackState.loading: return '載入中';
      case PlaybackState.playing: return '播放中';
      case PlaybackState.paused: return '已暫停';
      case PlaybackState.error: return '錯誤';
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isSaving = true);
    try {
      final newDeviceId = _deviceIdController.text.trim();
      final newBrokerHost = _brokerHostController.text.trim();
      final newApiUrl = _apiServerUrlController.text.trim();

      if (newDeviceId.isEmpty || newBrokerHost.isEmpty || newApiUrl.isEmpty) {
        _showMessage('欄位不可為空');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfig.deviceIdKey, newDeviceId);
      await prefs.setString(AppConfig.mqttBrokerHostKey, newBrokerHost);
      await prefs.setString(AppConfig.apiServerUrlKey, newApiUrl);
      
      await widget.onDeviceRoleChanged(_deviceRole);

      await widget.mqttManager.updateBrokerHost(newBrokerHost);
      await widget.mqttManager.updateDeviceId(newDeviceId);
      
      // 動態更新 API Base URL
      widget.downloadManager.updateBaseUrl(newApiUrl);

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

  Future<void> _confirmDeleteVideo(PlaybackInfo item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認刪除'),
        content: Text('確定要刪除 "${item.filename}" 嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
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
    _apiServerUrlController.dispose();
    super.dispose();
  }
}
