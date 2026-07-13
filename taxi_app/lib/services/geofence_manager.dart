import 'package:geolocator/geolocator.dart';
import '../models/lbs_campaign.dart';
import '../models/play_ad_command.dart';

class GeofenceManager {
  final List<LbsCampaign> _activeCampaigns = [];
  String? _currentActiveCampaignId;

  // 觸發事件：傳遞你的 Command 列表
  Function(String campaignId, List<PlayAdCommand> playCmds, List<DownloadVideoCommand> dlCmds)? onEnterHighestPriorityZone;
  Function()? onExitAllZones;

  void updateLbsCampaigns(List<LbsCampaign> campaigns) {
    _activeCampaigns.clear();
    _activeCampaigns.addAll(campaigns);
  }

  void processLocationUpdate(Position position) {
    if (_activeCampaigns.isEmpty) return;

    final insideZones = <LbsCampaign>[];

    // 1. 找出所有身處其中的圍欄
    for (final campaign in _activeCampaigns) {
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        campaign.latitude,
        campaign.longitude,
      );

      if (distance <= campaign.radiusInMeters) {
        insideZones.add(campaign);
      }
    }

    // 2. 離開所有區域
    if (insideZones.isEmpty) {
      if (_currentActiveCampaignId != null) {
        _currentActiveCampaignId = null;
        onExitAllZones?.call();
      }
      return;
    }

    // 3. 處理重疊區域：依優先級 (lbsPriority) 降序排列
    insideZones.sort((a, b) => b.lbsPriority.compareTo(a.lbsPriority));
    final highestCampaign = insideZones.first;

    // 4. 狀態改變，觸發進入事件
    if (_currentActiveCampaignId != highestCampaign.campaignId) {
      _currentActiveCampaignId = highestCampaign.campaignId;

      onEnterHighestPriorityZone?.call(
        highestCampaign.campaignId,
        highestCampaign.playCommands,
        highestCampaign.downloadCommands,
      );
    }
  }
}