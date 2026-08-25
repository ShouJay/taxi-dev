# Taxi 車載廣告 App

Flutter 車載播放端，透過 MQTT 同步播放清單，並使用 HTTP 分片下載影片。

開發環境目前連線 Azure VM：

- HTTP API：`http://13.70.26.4:8080`
- MQTT Broker：`13.70.26.4:1883`

## 開發建置

```bash
flutter pub get
flutter run --flavor dev --dart-define-from-file=config/dev.json
flutter build apk --debug --flavor dev --dart-define-from-file=config/dev.json
```

`config/dev.json` 與 development 預設值都指向上述 VM。舊版 App 若曾儲存 `localhost`、`10.0.2.2` 或舊 LAN IP，升級後會自動遷移到 VM。

## Staging / Production

1. 複製 `config/staging.example.json` 或 `config/production.example.json`。
2. 填入 HTTPS API、TLS MQTT Broker 與身分驗證。
3. 不要將真實密碼設定檔 commit 進 Git。

```bash
flutter build apk \
  --release \
  --flavor production \
  --dart-define-from-file=config/production.json
```

Production 建置會拒絕 localhost、非 HTTPS API、非 TLS MQTT 或缺少 MQTT 身分驗證的設定。

## Android 簽署

複製 `android/key.properties.example` 為 `android/key.properties`，並指向正式 keystore。`key.properties` 和 keystore 已被 Git 忽略；production release 在缺少簽署設定時會直接失敗。

## 驗證

```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
```
