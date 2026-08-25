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
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('系統設定', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: widget.onBack,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildDeviceSettingsCard(),
              const SizedBox(height: 24),
              _buildStatusSection(),
              const SizedBox(height: 24),
              _buildDownloadsSection(),
              const SizedBox(height: 24),
              _buildPlaylistSection(),
              const SizedBox(height: 24),
              _buildActionsSection(),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'Taxi App v2.0.0 (MQTT)',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.blue[700]),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.grey[800],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSettingsCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('設備與連線設定', Icons.settings_applications),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                TextField(
                  controller: _deviceIdController,
                  decoration: InputDecoration(
                    labelText: '設備 ID',
                    hintText: '例如: taxi-AAB-1234-rooftop',
                    prefixIcon: const Icon(Icons.devices, color: Colors.blue),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey[50],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _brokerHostController,
                  decoration: InputDecoration(
                    labelText: 'MQTT Broker 位址',
                    hintText: '例如: 10.0.2.2 或 192.168.x.x',
                    prefixIcon: const Icon(Icons.hub, color: Colors.blue),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey[50],
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    labelText: '設備角色',
                    prefixIcon: const Icon(Icons.tv, color: Colors.blue),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey[50],
                  ),
                  value: _deviceRole,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: 'SCREEN_A',
                      child: Text('SCREEN_A — 廣告屏（跑馬燈）'),
                    ),
                    DropdownMenuItem(
                      value: 'SCREEN_B',
                      child: Text('SCREEN_B — 互動屏（QR / 警報）'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _deviceRole = value);
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.blue[100]!),
                  ),
                  child: SwitchListTile(
                    title: const Text('管理員模式', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('開啟後顯示詳細調試資訊', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    value: _isAdminMode,
                    onChanged: _isUpdatingAdminMode ? null : _handleAdminModeChanged,
                    activeColor: Colors.blue,
                    secondary: Icon(
                      _isAdminMode ? Icons.admin_panel_settings : Icons.visibility_off,
                      color: _isAdminMode ? Colors.blue : Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _saveSettings,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.save),
                    label: Text(_isSaving ? '儲存中...' : '儲存設定', style: const TextStyle(fontSize: 16)),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusSection() {
    final isConnected = widget.mqttManager.isConnected;
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('系統狀態監控', Icons.monitor_heart),
        Row(
          children: [
            Expanded(
              child: _buildMiniStatusCard(
                'MQTT 連線',
                isConnected ? '已連線' : '未連線',
                isConnected ? Icons.cloud_done : Icons.cloud_off,
                isConnected ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMiniStatusCard(
                '播放狀態',
                _getPlaybackStateText(),
                Icons.play_circle_fill,
                Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildStatusRow(Icons.dns, Colors.blue, 'Broker', '${widget.mqttManager.brokerHost}:${AppConfig.mqttBrokerPort}'),
                const Divider(height: 24),
                _buildStatusRow(Icons.access_time, Colors.blueGrey, '最後更新', _lastUpdate),
                if (widget.locationService != null) ...[
                  const Divider(height: 24),
                  _buildStatusRow(Icons.location_on, Colors.green, 'GPS 狀態', widget.locationService!.getLocationAckStatus()),
                  const Divider(height: 24),
                  _buildStatusRow(Icons.analytics, Colors.purple, '位置上報次數', '${widget.locationService!.sentCount} 次'),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMiniStatusCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 8),
            Text(title, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(IconData icon, Color iconColor, String label, String value) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: iconColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 16),
        Text(label, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
        const Spacer(),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildActionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('系統操作', Icons.build_circle),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testPlayDefaultVideo,
                icon: const Icon(Icons.play_arrow),
                label: const Text('測試播放'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _reconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('重連 MQTT'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownloadsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('下載進度', Icons.downloading),
        if (_activeDownloads.isEmpty)
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.check_circle_outline, size: 32, color: Colors.grey[400]),
                    const SizedBox(height: 8),
                    Text('目前沒有進行中的下載任務', style: TextStyle(color: Colors.grey[500])),
                  ],
                ),
              ),
            ),
          )
        else
          Column(
            children: _activeDownloads.values.map((task) {
              return Card(
                elevation: 1,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.file_download, size: 18, color: Colors.blue[600]),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              task.downloadInfo.filename,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text('${task.progress}%', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue[700])),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: task.progress / 100,
                          minHeight: 8,
                          backgroundColor: Colors.grey[200],
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue[500]!),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildPlaylistSection() {
    final playlist = widget.playbackManager.getFullPlaylist();
    final systemPlaylist = playlist.where((item) => !item.isLocalVideo).toList();
    final localPlaylist = playlist.where((item) => item.isLocalVideo).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('播放列表', Icons.video_library),
        _buildPlaylistGroup(
          title: '系統排程 / 活動影片',
          emptyHint: '目前沒有系統排程影片',
          items: systemPlaylist,
          icon: Icons.cloud_download,
        ),
        const SizedBox(height: 16),
        _buildPlaylistGroup(
          title: '本地預設影片',
          emptyHint: '尚未匯入本地影片',
          items: localPlaylist,
          icon: Icons.folder,
        ),
      ],
    );
  }

  Widget _buildPlaylistGroup({
    required String title,
    required String emptyHint,
    required List<PlaybackInfo> items,
    required IconData icon,
  }) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, size: 20, color: Colors.blue[600]),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${items.length}', style: TextStyle(color: Colors.blue[700], fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(emptyHint, style: TextStyle(color: Colors.grey[500])),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) => _buildPlaylistItem(items[index]),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaylistItem(PlaybackInfo item) {
    final isPlaying = item.isCurrentPlaying;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isPlaying ? Colors.green[50] : Colors.blue[50],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          isPlaying ? Icons.play_arrow : Icons.movie,
          color: isPlaying ? Colors.green : Colors.blue,
        ),
      ),
      title: Text(
        item.title,
        style: TextStyle(
          fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
          color: isPlaying ? Colors.green[700] : Colors.black87,
        ),
      ),
      subtitle: Text(item.filename, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      trailing: item.isLocalVideo
          ? IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () => _confirmDeleteVideo(item),
              tooltip: '刪除',
            )
          : null,
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
    super.dispose();
  }
}
