import 'package:taxi_app/models/play_ad_command.dart';

class LbsCampaign {
  final String campaignId;
  final double latitude;
  final double longitude;
  final double radiusInMeters;
  final int lbsPriority; // 數字越大優先級越高

  // 💡 核心：將你的指令 Model 包含進來
  final List<PlayAdCommand> playCommands;
  final List<DownloadVideoCommand> downloadCommands;

  LbsCampaign({
    required this.campaignId,
    required this.latitude,
    required this.longitude,
    required this.radiusInMeters,
    required this.lbsPriority,
    required this.playCommands,
    required this.downloadCommands,
  });

  factory LbsCampaign.fromJson(Map<String, dynamic> json) {
    return LbsCampaign(
      campaignId: json['campaign_id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      radiusInMeters: (json['radius'] as num).toDouble(),
      lbsPriority: json['lbs_priority'] as int? ?? 0,

      // 解析播放指令
      playCommands: (json['play_commands'] as List<dynamic>?)
          ?.map((e) => PlayAdCommand.fromJson(e as Map<String, dynamic>))
          .toList() ?? [],

      // 解析下載指令
      downloadCommands: (json['download_commands'] as List<dynamic>?)
          ?.map((e) => DownloadVideoCommand.fromJson(e as Map<String, dynamic>))
          .toList() ?? [],
    );
  }
}