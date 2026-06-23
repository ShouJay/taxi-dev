import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import '../config/app_config.dart';
import '../models/download_info.dart';

/// 下載任務
class DownloadTask {
  final String advertisementId;
  final DownloadInfo downloadInfo;
  DownloadStatus status;
  int progress;
  List<int> downloadedChunks;
  String? errorMessage;
  File? outputFile;

  DownloadTask({
    required this.advertisementId,
    required this.downloadInfo,
    this.status = DownloadStatus.pending,
    this.progress = 0,
    List<int>? downloadedChunks,
    this.errorMessage,
    this.outputFile,
  }) : downloadedChunks = downloadedChunks ?? [];

  int get totalChunks => downloadInfo.totalChunks;
}

/// 下載管理器
class DownloadManager {
  final String baseUrl;
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, StreamController<DownloadTask>> _progressControllers = {};

  DownloadManager({required this.baseUrl});

  /// 獲取下載資訊
  Future<DownloadInfo?> getDownloadInfo(
    String advertisementId, {
    int chunkSize = AppConfig.defaultChunkSize,
  }) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/device/videos/$advertisementId/download',
      ).replace(queryParameters: {'chunk_size': chunkSize.toString()});

      print('📋 獲取下載資訊: $uri');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final downloadInfo = DownloadInfo.fromJson(data['download_info']);
        print('✅ 下載資訊獲取成功: ${downloadInfo.filename}');
        print('   檔案大小: ${downloadInfo.fileSize} bytes');
        print('   分片大小: ${downloadInfo.chunkSize} bytes');
        print('   總分片數: ${downloadInfo.totalChunks}');
        return downloadInfo;
      } else {
        print('❌ 獲取下載資訊失敗: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ 獲取下載資訊錯誤: $e');
      return null;
    }
  }

  /// 下載單個分片
  Future<Uint8List?> downloadChunk({
    required String advertisementId,
    required int chunkNumber,
    required int chunkSize,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/device/videos/$advertisementId/chunk')
          .replace(
            queryParameters: {
              'chunk': chunkNumber.toString(),
              'chunk_size': chunkSize.toString(),
            },
          );

      final response = await http.get(uri);

      if (response.statusCode == 200) {
        print('✅ 分片 $chunkNumber 下載完成 (${response.bodyBytes.length} bytes)');
        return response.bodyBytes;
      } else {
        print('❌ 下載分片 $chunkNumber 失敗: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('❌ 下載分片 $chunkNumber 錯誤: $e');
      return null;
    }
  }

  /// 開始下載影片
  Future<bool> startDownload({
    required String advertisementId,
    String? expectedMd5,
    Function(DownloadTask)? onProgress,
    Function()? onPlaybackCheck,
  }) async {
    // 檢查是否已經在下載 (這個檢查仍然需要)
    if (_tasks.containsKey(advertisementId) &&
        _tasks[advertisementId]!.status == DownloadStatus.downloading) {
      print('⚠️ 影片 $advertisementId 正在下載中');

      // 🔽🔽🔽 修改點 A: 如果已在下載，也要綁定 onProgress 🔽🔽🔽
      if (onProgress != null) {
        _progressControllers[advertisementId]?.stream.listen(onProgress);
      }
      return false;
    }

    // 檢查是否正在播放（播放中不能下載）
    if (onPlaybackCheck != null) {
      onPlaybackCheck();
      // 注意：這裡不阻止下載，由調用者決定是否需要檢查
    }

    try {
      // 獲取下載資訊
      final downloadInfo = await getDownloadInfo(advertisementId);
      if (downloadInfo == null) {
        print('❌ 無法獲取下載資訊');
        return false;
      }

      // 🔽🔽🔽 修改點 B: 提早建立控制器 🔽🔽🔽
      // 提早建立或獲取控制器，以便我們可以立即發送「已完成」通知
      final controller = _progressControllers.putIfAbsent(
        advertisementId,
        () => StreamController<DownloadTask>.broadcast(),
      );
      if (onProgress != null) {
        // 這裡可以加上邏輯防止重複監聽，但為簡潔起見暫時省略
        controller.stream.listen(onProgress);
      }
      // 🔼🔼🔼 修改點 B: 結束 🔼🔼🔼

      // 檢查檔案是否已存在
      final videoPath = await _getVideoPath(downloadInfo.filename);
      final file = File(videoPath);

      if (await file.exists()) {
        // 驗證已存在的檔案（大小和格式）
        final validationResult = await _validateDownloadedFile(
          file,
          downloadInfo,
        );

        if (validationResult.isValid) {
          // MD5 校驗（若後端有提供）
          if (expectedMd5 != null && expectedMd5.isNotEmpty) {
            final md5Ok = await verifyFileMd5(
              downloadInfo.filename,
              expectedMd5: expectedMd5,
            );
            if (!md5Ok) {
              print('⚠️ 既有檔案 MD5 不符，重新下載');
              await file.delete();
            } else {
              print('✅ 檔案已存在且 MD5 驗證通過: ${downloadInfo.filename}');
              final completedTask = DownloadTask(
                advertisementId: advertisementId,
                downloadInfo: downloadInfo,
                status: DownloadStatus.completed,
                progress: 100,
                outputFile: file,
              );
              scheduleMicrotask(() => _notifyProgress(completedTask));
              return true;
            }
          } else {
            print('✅ 檔案已存在且驗證通過: ${downloadInfo.filename}');
            final completedTask = DownloadTask(
              advertisementId: advertisementId,
              downloadInfo: downloadInfo,
              status: DownloadStatus.completed,
              progress: 100,
              outputFile: file,
            );
            scheduleMicrotask(() => _notifyProgress(completedTask));
            return true;
          }
        } else {
          // 驗證失敗，刪除檔案並重新下載
          print('⚠️ 檔案驗證失敗，重新下載: ${downloadInfo.filename}');
          print('   錯誤: ${validationResult.errorMessage}');
          if (await file.exists()) {
            await file.delete();
          }
        }
      }

      // 建立下載任務 (如果檔案不存在或大小不符)
      final task = DownloadTask(
        advertisementId: advertisementId,
        downloadInfo: downloadInfo,
        status: DownloadStatus.downloading,
        outputFile: file,
      );
      _tasks[advertisementId] = task;

      // (控制器已在前面建立)
      _notifyProgress(task); // 通知「正在下載」

      // 開始背景下載
      _downloadInBackground(task, expectedMd5: expectedMd5);

      return true;
    } catch (e) {
      print('❌ 啟動下載失敗: $e');
      return false;
    }
  }

  /// 背景下載
  Future<void> _downloadInBackground(
    DownloadTask task, {
    String? expectedMd5,
  }) async {
    final downloadInfo = task.downloadInfo;
    final advertisementId = task.advertisementId;

    try {
      // 建立輸出檔案
      final file = task.outputFile!;
      final fileWriter = file.openWrite();

      // 下載每個分片
      for (int i = 0; i < downloadInfo.totalChunks; i++) {
        // 檢查是否已下載
        if (task.downloadedChunks.contains(i)) {
          continue;
        }

        // 下載分片（支援重試）
        Uint8List? chunkData;
        int retryCount = 0;

        while (retryCount < AppConfig.downloadRetryAttempts) {
          chunkData = await downloadChunk(
            advertisementId: advertisementId,
            chunkNumber: i,
            chunkSize: downloadInfo.chunkSize,
          );

          if (chunkData != null) {
            break;
          }

          retryCount++;
          if (retryCount < AppConfig.downloadRetryAttempts) {
            print('🔄 重試下載分片 $i (第 $retryCount 次)');
            await Future.delayed(Duration(seconds: retryCount * 2));
          }
        }

        if (chunkData == null) {
          // 下載失敗
          task.status = DownloadStatus.failed;
          task.errorMessage = '下載分片 $i 失敗';
          _notifyProgress(task);
          await fileWriter.close();
          await file.delete();
          return;
        }

        // 寫入分片
        fileWriter.add(chunkData);
        task.downloadedChunks.add(i);

        // 更新進度
        task.progress =
            ((task.downloadedChunks.length / downloadInfo.totalChunks) * 100)
                .round();
        _notifyProgress(task);
      }

      // 完成下載
      await fileWriter.close();

      // 🔽🔽🔽 驗證下載的檔案 🔽🔽🔽
      final validationResult = await _validateDownloadedFile(
        file,
        downloadInfo,
      );

      if (!validationResult.isValid) {
        task.status = DownloadStatus.failed;
        task.errorMessage = validationResult.errorMessage;
        _notifyProgress(task);
        if (await file.exists()) await file.delete();
        return;
      }

      // MD5 完整性校驗
      if (expectedMd5 != null && expectedMd5.isNotEmpty) {
        final md5Ok = await verifyFileMd5(
          downloadInfo.filename,
          expectedMd5: expectedMd5,
        );
        if (!md5Ok) {
          task.status = DownloadStatus.failed;
          task.errorMessage = 'MD5_MISMATCH';
          _notifyProgress(task);
          await file.delete();
          print('❌ MD5 校驗失敗，已刪除: ${downloadInfo.filename}');
          return;
        }
      }

      task.status = DownloadStatus.completed;
      task.progress = 100;
      _notifyProgress(task);

      print('✅ 下載完成: ${downloadInfo.filename}');
      print('   路徑: ${file.path}');
      print(
        '   檔案大小: ${validationResult.actualFileSize} bytes (預期: ${downloadInfo.fileSize} bytes)',
      );
      print('   格式驗證: ${validationResult.formatValid ? "通過" : "失敗"}');
    } catch (e) {
      print('❌ 下載過程錯誤: $e');
      task.status = DownloadStatus.failed;
      task.errorMessage = e.toString();
      _notifyProgress(task);

      // 清理失敗的檔案
      if (task.outputFile != null && await task.outputFile!.exists()) {
        await task.outputFile!.delete();
      }
    }
  }

  /// 通知進度更新
  void _notifyProgress(DownloadTask task) {
    final controller = _progressControllers[task.advertisementId];
    if (controller != null && !controller.isClosed) {
      controller.add(task);
    }
  }

  /// 取消下載
  Future<void> cancelDownload(String advertisementId) async {
    final task = _tasks[advertisementId];
    if (task != null) {
      task.status = DownloadStatus.paused;
      _notifyProgress(task);

      // 清理未完成的檔案
      if (task.outputFile != null && await task.outputFile!.exists()) {
        await task.outputFile!.delete();
      }

      _tasks.remove(advertisementId);
      _progressControllers[advertisementId]?.close();
      _progressControllers.remove(advertisementId);

      print('⏸️ 已取消下載: $advertisementId');
    }
  }

  /// 獲取任務狀態
  DownloadTask? getTask(String advertisementId) {
    return _tasks[advertisementId];
  }

  /// 獲取所有下載任務（用於檢查是否有正在下載的任務）
  List<DownloadTask> getAllTasks() {
    return _tasks.values.toList();
  }

  /// 檢查是否有正在下載的任務（用於互斥邏輯）
  bool isDownloading() {
    return _tasks.values.any(
      (task) => task.status == DownloadStatus.downloading,
    );
  }

  /// 獲取所有正在下載的任務
  List<DownloadTask> getActiveDownloads() {
    return _tasks.values
        .where((task) => task.status == DownloadStatus.downloading)
        .toList();
  }

  /// 獲取影片路徑
  Future<String> _getVideoPath(String filename) async {
    final directory = await getApplicationDocumentsDirectory();
    final videoDir = Directory('${directory.path}/videos');

    if (!await videoDir.exists()) {
      await videoDir.create(recursive: true);
    }

    return '${videoDir.path}/$filename';
  }

  /// 檢查影片是否存在
  Future<bool> isVideoExists(String filename) async {
    final videoPath = await _getVideoPath(filename);
    final file = File(videoPath);
    return await file.exists();
  }

  /// 獲取影片完整路徑
  Future<String> getVideoPath(String filename) async {
    return await _getVideoPath(filename);
  }

  /// 獲取所有已下載的影片列表
  Future<List<String>> getAllDownloadedVideos() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final videoDir = Directory('${directory.path}/videos');

      if (!await videoDir.exists()) {
        return [];
      }

      final files = await videoDir.list().toList();
      final videoFiles = files
          .where((file) => file is File)
          .map((file) => file.path.split('/').last)
          .where(
            (filename) =>
                filename.endsWith('.mp4') ||
                filename.endsWith('.mov') ||
                filename.endsWith('.avi'),
          )
          .toList();

      print('📁 找到 ${videoFiles.length} 個已下載的影片');
      for (var filename in videoFiles) {
        print('   - $filename');
      }

      return videoFiles;
    } catch (e) {
      print('❌ 獲取已下載影片列表失敗: $e');
      return [];
    }
  }

  /// 驗證下載的檔案（大小和格式）
  Future<FileValidationResult> _validateDownloadedFile(
    File file,
    DownloadInfo downloadInfo,
  ) async {
    try {
      // 1. 檢查檔案是否存在
      if (!await file.exists()) {
        return FileValidationResult(
          isValid: false,
          errorMessage: '檔案不存在',
          actualFileSize: 0,
          formatValid: false,
        );
      }

      // 2. 驗證檔案大小
      final actualFileSize = await file.length();
      final expectedFileSize = downloadInfo.fileSize;

      // 允許 1% 的誤差（考慮可能的檔案系統差異）
      final sizeDifference = (actualFileSize - expectedFileSize).abs();
      final allowedDifference = (expectedFileSize * 0.01).round();

      if (sizeDifference > allowedDifference) {
        return FileValidationResult(
          isValid: false,
          errorMessage:
              '檔案大小不符: 實際 ${actualFileSize} bytes，預期 ${expectedFileSize} bytes (差異: ${sizeDifference} bytes)',
          actualFileSize: actualFileSize,
          formatValid: false,
        );
      }

      print('✅ 檔案大小驗證通過: ${actualFileSize} bytes');

      // 3. 驗證檔案格式（檢查檔案擴展名和檔案頭部）
      final formatValid = await _validateVideoFormat(
        file,
        downloadInfo.filename,
      );

      if (!formatValid) {
        return FileValidationResult(
          isValid: false,
          errorMessage: '檔案格式驗證失敗: 可能是損壞的影片檔案或不支援的格式',
          actualFileSize: actualFileSize,
          formatValid: false,
        );
      }

      print('✅ 檔案格式驗證通過');

      return FileValidationResult(
        isValid: true,
        errorMessage: null,
        actualFileSize: actualFileSize,
        formatValid: true,
      );
    } catch (e) {
      return FileValidationResult(
        isValid: false,
        errorMessage: '驗證過程發生錯誤: $e',
        actualFileSize: 0,
        formatValid: false,
      );
    }
  }

  /// 驗證影片格式（檢查檔案頭部）
  Future<bool> _validateVideoFormat(File file, String filename) async {
    try {
      // 檢查檔案擴展名
      final extension = filename.toLowerCase().split('.').last;
      final supportedFormats = ['mp4', 'mov', 'avi', 'mkv', 'webm'];

      if (!supportedFormats.contains(extension)) {
        print('⚠️ 不支援的檔案擴展名: $extension');
        // 不立即失敗，繼續檢查檔案頭部
      }

      // 讀取檔案頭部（前 12 bytes）來驗證格式
      final randomAccessFile = await file.open();
      try {
        await randomAccessFile.setPosition(0);
        final headerBytes = await randomAccessFile.read(12);
        await randomAccessFile.close();

        if (headerBytes.length < 4) {
          print('⚠️ 檔案太小，無法讀取檔案頭');
          return false;
        }

        // 檢查常見的影片檔案格式標識
        // MP4/MOV: ftyp box 通常在 offset 4-8
        // AVI: 前 4 bytes 應該是 "RIFF"
        final first4Bytes = headerBytes.length >= 4
            ? String.fromCharCodes(headerBytes.sublist(0, 4))
            : '';
        final bytes4to8 = headerBytes.length >= 8
            ? String.fromCharCodes(headerBytes.sublist(4, 8))
            : '';

        bool isValidFormat = false;

        // MP4/MOV 格式檢查：應包含 "ftyp" (通常在 offset 4)
        if (bytes4to8 == 'ftyp') {
          isValidFormat = true;
          print('✅ 檢測到 MP4/MOV 格式');
        }
        // AVI 格式檢查
        else if (first4Bytes == 'RIFF' &&
            headerBytes.length >= 12 &&
            String.fromCharCodes(headerBytes.sublist(8, 12)) == 'AVI ') {
          isValidFormat = true;
          print('✅ 檢測到 AVI 格式');
        }
        // WebM/MKV 格式檢查 (EBML 格式，以 0x1a 0x45 0xdf 0xa3 開頭)
        else if (headerBytes.length >= 4 &&
            headerBytes[0] == 0x1a &&
            headerBytes[1] == 0x45 &&
            headerBytes[2] == 0xdf &&
            headerBytes[3] == 0xa3) {
          isValidFormat = true;
          print('✅ 檢測到 WebM/MKV 格式');
        } else {
          // 如果無法識別格式，但檔案大小正確，可能仍然有效
          // 讓播放器來驗證（在播放時會檢查）
          print('⚠️ 無法識別檔案頭格式，將由播放器驗證');
          isValidFormat = true; // 暫時允許，讓播放器來最終驗證
        }

        return isValidFormat;
      } catch (e) {
        print('⚠️ 讀取檔案頭時發生錯誤: $e');
        // 如果無法讀取檔案頭，但檔案大小正確，仍然允許
        // 讓播放器來驗證
        return true;
      }
    } catch (e) {
      print('❌ 驗證影片格式時發生錯誤: $e');
      return false;
    }
  }

  /// 計算並驗證檔案 MD5
  Future<bool> verifyFileMd5(
    String filename, {
    required String expectedMd5,
  }) async {
    try {
      final path = await _getVideoPath(filename);
      final file = File(path);
      if (!await file.exists()) return false;

      final digest = await computeFileMd5(file);
      final ok = digest.toLowerCase() == expectedMd5.toLowerCase();
      if (!ok) {
        print('❌ MD5 不符: 本地=$digest, 期望=$expectedMd5');
      }
      return ok;
    } catch (e) {
      print('❌ MD5 驗證錯誤: $e');
      return false;
    }
  }

  /// 計算檔案 MD5
  Future<String> computeFileMd5(File file) async {
    final bytes = await file.readAsBytes();
    return md5.convert(bytes).toString();
  }

  /// 刪除指定影片檔案
  Future<bool> deleteVideoFile(String filename) async {
    try {
      final path = await _getVideoPath(filename);
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        print('🗑️ 已刪除影片: $filename');
        return true;
      }
      return false;
    } catch (e) {
      print('❌ 刪除影片失敗: $e');
      return false;
    }
  }

  /// 清理所有任務
  void dispose() {
    for (final controller in _progressControllers.values) {
      controller.close();
    }
    _progressControllers.clear();
    _tasks.clear();
  }
}

/// 檔案驗證結果
class FileValidationResult {
  final bool isValid;
  final String? errorMessage;
  final int actualFileSize;
  final bool formatValid;

  FileValidationResult({
    required this.isValid,
    this.errorMessage,
    required this.actualFileSize,
    required this.formatValid,
  });
}
