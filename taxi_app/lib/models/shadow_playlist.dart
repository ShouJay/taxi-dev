/// Device Shadow — 期望播放清單中的單支影片
class DesiredVideo {
  final String videoId;
  final String url;
  final String? md5;
  final int? fileSize;
  final String? videoFilename;

  DesiredVideo({
    required this.videoId,
    required this.url,
    this.md5,
    this.fileSize,
    this.videoFilename,
  });

  factory DesiredVideo.fromJson(Map<String, dynamic> json) {
    final videoId =
        json['video_id'] as String? ??
        json['advertisement_id'] as String? ??
        '';
    return DesiredVideo(
      videoId: videoId,
      url: json['url'] as String? ?? '',
      md5: json['md5'] as String?,
      fileSize: json['file_size'] as int?,
      videoFilename: json['video_filename'] as String?,
    );
  }

  // 💡 新增這個 toJson 方法
  Map<String, dynamic> toJson() => {
    'video_id': videoId,
    'url': url,
    'md5': md5,
    'file_size': fileSize,
    'video_filename': videoFilename,
  };
}

/// 後端下發的期望狀態（taxi/{id}/playlist/desired）
class DesiredPlaylist {
  final String? campaignId;
  final List<DesiredVideo> videos;
  final String? updatedAt;
  final Map<String, dynamic>? command;

  DesiredPlaylist({
    this.campaignId,
    required this.videos,
    this.updatedAt,
    this.command,
  });

  factory DesiredPlaylist.fromJson(Map<String, dynamic> json) {
    final rawVideos = json['videos'] as List<dynamic>? ?? [];
    return DesiredPlaylist(
      campaignId: json['campaign_id'] as String?,
      videos: rawVideos
          .whereType<Map<String, dynamic>>()
          .map(DesiredVideo.fromJson)
          .toList(),
      updatedAt: json['updated_at'] as String?,
      command: json['command'] as Map<String, dynamic>?,
    );
  }

  String? get commandType => command?['command'] as String?;

  // 💡 新增這個 toJson 方法
  Map<String, dynamic> toJson() => {
    'campaign_id': campaignId,
    'videos': videos.map((v) => v.toJson()).toList(),
    'updated_at': updatedAt,
    'command': command,
  };
}

/// 本地影片庫存狀態
enum LocalVideoStatus { ready, downloading, failed, missing }

class LocalVideoInventory {
  final String videoId;
  final LocalVideoStatus status;
  final int progress;
  final String? localMd5;

  LocalVideoInventory({
    required this.videoId,
    required this.status,
    this.progress = 0,
    this.localMd5,
  });

  Map<String, dynamic> toJson() {
    return {
      'video_id': videoId,
      'status': status.name,
      'progress': progress,
      if (localMd5 != null) 'local_md5': localMd5,
    };
  }
}

/// 回報錯誤
class ReportedError {
  final String videoId;
  final String code;
  final String message;

  ReportedError({
    required this.videoId,
    required this.code,
    required this.message,
  });

  Map<String, dynamic> toJson() => {
    'video_id': videoId,
    'code': code,
    'msg': message,
  };
}

/// 緊急廣播 / 系統狀態（taxi/all/emergency）
class EmergencyState {
  final bool isAlarmActive;
  final String marqueeText;
  final String emergencyVideo;
  final int qrScanCount;
  final String? type;

  EmergencyState({
    this.isAlarmActive = false,
    this.marqueeText = '',
    this.emergencyVideo = 'earthquake_alert.mp4',
    this.qrScanCount = 0,
    this.type,
  });

  factory EmergencyState.fromJson(Map<String, dynamic> json) {
    return EmergencyState(
      isAlarmActive: json['is_alarm_active'] as bool? ?? false,
      marqueeText: json['marquee_text'] as String? ?? '',
      emergencyVideo: json['emergency_video'] as String? ?? 'earthquake_alert.mp4',
      qrScanCount: json['qr_scan_count'] as int? ?? 0,
      type: json['type'] as String?,
    );
  }
}
