這是一份為你量身打造的 Robust Taxi App 系統架構演進技術文檔。整份文檔採用標準 Markdown 格式編寫，將系統描述、Before/After 架構圖（Mermaid 語法）以及核心機制對比完整整合。
你可以直接複製整份內容，覆蓋到專案的 ARCHITECTURE_EVOLUTION.md 或 README.md 中。
🚀 Robust Taxi App — 系統架構演進技術文檔 (WebSocket ➡️ MQTT)
本文件記錄了 Robust Taxi App (v2.0.0) 為了因應未來「大規模車載螢幕部署」與「不穩定移動網路環境」，將核心即時通訊層從 WebSocket (Flask-SocketIO) 全面優化為 MQTT (物聯網設備影子模式) 的架構演進細節。
📌 核心架構演進矩陣 (Matrix)
維度	Before (WebSocket 架構)	After (MQTT 影子架構)
通訊中樞	Flask 後端服務（記憶體管理、強耦合）	EMQX Broker（物聯網專用、完全解耦）
通訊模式	點對點 (Point-to-Point) 雙向連線	發布 / 訂閱 (Publish / Subscribe) 階層主題
終端設備角色	主動參與業務、連線維護邏輯複雜	啞終端 (Dumb Terminal)、狀態驅動自檢
大規模推送	後端需寫 for 迴圈逐一發送給各 Session，開銷大	透過 Topic 廣播或分組訂閱，一次發布全網同步
移動網路斷線	頻繁引發 HTTP 握手 (Handshake)，易死鎖	內建 Keep-Alive、LWT（遺言）與離線快取補發
影片完整性	無校驗機制，斷線重傳易導致檔案損毀黑畫面	強制 MD5 雜湊值校驗，損毀自動重傳與報警
系統擴展性	困難，受限於 Python 異步天花板，需綁定 Redis	極易，後端 Worker 與 API Server 可無限水平擴展
── BEFORE ──
原本架構：WebSocket / Flask-SocketIO (點對點強耦合)
在原本的單體原型架構中，後端 Flask 同時承載了 HTTP REST API 與 WebSocket 長連線管理 的雙重職責。當車載端數量激增時，Python 進程為了維持與數萬台平板的心跳與連線映射，會耗盡伺服器的 CPU 與記憶體資源。
flowchart TB
    subgraph clients [客戶端 / 互動端]
        Flutter[taxi_app<br/>Flutter 車載 App]
        AdminWeb[admin_dashboard.html<br/>管理後台]
        ControlWeb[control_panel.html<br/>雙螢幕中控台]
    end

    subgraph backend [robust_taxi 後端單一核心]
        AppLayer[app.py<br/>HTTP + WebSocket 連線控管]
        AdminBP[admin_api.py<br/>管理 REST API]
        DualBP[dual_screen_api.py<br/>雙螢幕 API]
        Services[services.py<br/>LBS 決策服務]
        Emergency[emergency_manager.py<br/>緊急狀態機]
    end

    MongoDB[(MongoDB<br/>儲存設備與圍欄資料)]

    %% 連線關係
    Flutter -->|1. WebSocket: 位置上報 & 註冊| AppLayer
    Flutter -->|2. HTTP: 影片分片下載| AppLayer
    AdminWeb -->|HTTP REST| AdminBP
    ControlWeb -->|HTTP REST| DualBP

    AppLayer --> Services
    AppLayer --> Emergency
    Services --> MongoDB
    AdminBP --> MongoDB
    
    %% 強制推送
    AppLayer -->|3. WebSocket: play_ad / start_campaign<br/>後端寫迴圈逐一發送給各 Session| Flutter

── AFTER ──
修改後架構：MQTT + Device Shadow (高擴展物聯網)
優化後的架構引入了 EMQX 物聯網消息代理伺服器。將連線壓力與狀態維持完全從 Flask 中解耦。
車載端全面落實**「零接觸部署（Zero-Touch Deployment）」**，出廠僅需設定一個唯一 ID，後續的影片下載、垃圾回收、損毀自檢，全部透過「期望狀態（Desired）」與「回報狀態（Reported）」自動同步。
flowchart TB
    subgraph clients [客戶端 / 啞終端]
        Flutter[taxi_app<br/>Flutter 車載 App<br/>出廠僅設定 ID / 背景自檢]
        AdminWeb[admin_dashboard.html<br/>管理後台 Web]
        ControlWeb[control_panel.html<br/>雙螢幕中控]
    end

    subgraph broker [MQTT 消息佇列中樞]
        EMQX[EMQX Broker<br/>扛下數萬台設備連線、心跳與 Pub/Sub]
    end

    subgraph backend [robust_taxi 後端解耦微服務]
        Worker[mqtt_worker.py<br/>LBS Worker 異步處理]
        Flask[app.py<br/>純 REST API & 影片分片 CDN]
        Emergency[emergency_manager.py<br/>緊急事件廣播器]
    end

    MongoDB[(MongoDB<br/>儲存設備/圍欄<br/>增設 Desired/Reported 快取)]

    %% 啞終端通訊
    Flutter -->|1. Pub: taxi/{id}/location (QoS 0)| EMQX
    Flutter -->|4. Pub: taxi/{id}/playlist/reported (QoS 1)<br/>含本地影片 MD5 狀況| EMQX
    EMQX -->|3. Sub: taxi/{id}/playlist/desired| Flutter
    EMQX -->|6. Sub: taxi/all/emergency| Flutter
    
    %% 檔案下載流（完全分流）
    Flutter -->|5. HTTP GET: 依據 URL 下載影片分片| Flask

    %% 後端運算流
    EMQX -->|2. 轉發設備位置| Worker
    Worker -->|地理圍欄查詢| MongoDB
    Worker -->|計算後 Pub: taxi/{id}/playlist/desired| EMQX
    
    %% 管理與緊急控制
    AdminWeb -->|HTTP REST| Flask
    Flask -->|更新配置與影片 MD5| MongoDB
    ControlWeb -->|MQTT over WS| Emergency
    Emergency -->|7. Pub: taxi/all/emergency (QoS 1)| EMQX

📡 MQTT 主題（Topic）設計規範
系統通訊全面改為結構化 Topic，所有傳輸的 Payload 皆為 JSON 格式：
Topic	方向	QoS	說明
taxi/{device_id}/location	App ➡️ 後端	0	週期性上報經緯度。移動環境允許丟包，不佔用重傳頻寬。
taxi/{device_id}/playlist/desired	後端 ➡️ App	1	後端下發的期望播放清單（含影片 URL、MD5、大小）。
taxi/{device_id}/playlist/reported	App ➡️ 後端	1	(Retained) App 回報的實際狀態與下載受損錯誤。
taxi/{device_id}/status	App ➡️ 後端	1	(LWT 遺言) 設備非正常斷網時，由 Broker 自動向後端發布離線通知。
taxi/all/emergency	後端 ➡️ App	1	全系統緊急插播、地震警報或跑馬燈控制廣播。
🛠️ 關鍵自動化自癒機制
為了確保車載端在無人操作的情況下穩定運行，新架構實作了以下物聯網邊界自癒邏輯：
1. 影片損毀完整性自檢 (MD5 Verification)
• 後端端：管理員上傳影片時，Flask 會自動計算該影片的 MD5 雜湊值（例如：e10adc3949ba59abbe56e057f20f883e）並寫入資料庫。
• 設備端：Flutter 下載完影片分片並組裝後，必須在背景計算檔案的 MD5。 • 本地 MD5 == 期望 MD5 ➡️ 檔案完好，標記為 ready。 • 本地 MD5 != 期望 MD5 ➡️ 判定檔案受損，自動物理刪除，並向 reported 主題發送錯誤日誌： "errors": [{"video_id": "v_xyz789", "code": "MD5_MISMATCH", "msg": "File corrupted, retrying..."}]
2. 播放防呆降級保護 (Fallback Mechanism)
當車載 App 收到包含全新影片的 desired 播放清單時：
• 不立刻切換：背景默默啟動 HTTP 下載，當前螢幕持續循環播放本地已存在的完好舊廣告。
• 無縫切換：只有當最新清單中的所有影片均下載完畢且 MD5 校驗 100% 正確 時，播放器才會在一瞬間無縫切換至新活動，徹底杜絕下載期間黑畫面或閃退的窘境。
3. 磁碟空間垃圾回收 (Garbage Collection)
計程車車載平板儲存空間有限。Flutter 端每次對齊 desired 狀態時，會自動盤點磁碟：
• 凡是不在當前期望清單中，且屬於歷史留存的舊影片檔案，App 會啟動 LRU (Least Recently Used) 演算法自動進行物理刪除，騰出空間給新廣告，不需後端人工下達清理指令。
🗄️ 資料模型調整範例 (MongoDB 影子結構)
在 devices 集合中，新增 shadow 欄位以快取設備的最新期望與回報狀態，便於管理後台進行 Diff 對比：
{
  "_id": "taxi-AAB-1234-rooftop",
  "device_type": "SCREEN_A",
  "groups": ["taipei_fleet"],
  "last_location": { "type": "Point", "coordinates": [121.543, 25.033] },
  "shadow": {
    "desired": {
      "campaign_id": "camp_2026_marketing_01",
      "videos": [
        { "video_id": "v_ad_99", "url": "https://cdn.robust.com/99.mp4", "md5": "c33367701511b4f6020ec61ded352059" }
      ]
    },
    "reported": {
      "current_campaign_id": "camp_2026_old_05",
      "local_inventory": [
        { "video_id": "v_ad_99", "status": "downloading", "progress": 45 }
      ],
      "errors": []
    }
  }
}

📈 運維與部署建議
1. Broker 選擇：生產環境強烈建議使用 EMQX 5.x 分散式叢集 部署，其內建的 Dashboard 能讓你即時看見每台計程車的 MQTT 連線心跳與流量圖表。
2. CDN 分流：大流量下，影片檔案下載網址（desired 中的 url）請直接導向 Azure CDN 或 AWS CloudFront，切勿讓平板直接回伺服器拉大檔案，確保核心 API 不會被頻寬塞爆。