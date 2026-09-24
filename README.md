# FreeAudio

macOS 選單列音訊控制工具。用 Core Audio process tap 做到按應用程式調整音量、切換輸出裝置、多輸出與等化器，不需要安裝虛擬音訊驅動。

## 功能

- **輸入／輸出**：切換系統預設裝置、調整音量、靜音（沒有硬體靜音的裝置會把音量歸零）。靜音時滑桿變成灰色，拖動滑桿會自動解除靜音。
- **選單列圖示**：麥克風圖示，平常跟隨選單列顏色（淺色選單列是黑色）；所選麥克風靜音、沒有可用的麥克風，或所選麥克風未連接時，都是紅色斜線麥克風。
- **鎖定所選裝置**：喇叭和麥克風都以裝置 ID 精準比對，不看名稱。只有在 FreeAudio 裡選的裝置才算數：連接耳機等新裝置時 macOS 自動切換、或在控制中心切換，都會被改回所選裝置，面板上會顯示提示，可一鍵「改用」。找不到所選裝置時，會把 macOS 改用的裝置靜音（沒有靜音控制的裝置改用擷取方式靜音）並跳出警告，不會自動改用其他裝置；重新連接後自動恢復，也可以在警告或面板中按「改用…」。警告視窗不會卡住 FreeAudio 的其他操作。App 個別指定的輸出裝置不見時，該 App 會被靜音而不是改從其他裝置播放。可在設定視窗關閉。
- **麥克風靜音不會自己解除**：在 FreeAudio 靜音的麥克風，只有在 FreeAudio 解除靜音才會打開。macOS 會自己解除麥克風靜音，例如用內建喇叭播放時「嘿 Siri」開始聆聽，或通話的語音處理隨著切換喇叭重新開始；FreeAudio 會立即重新靜音（實測約 1 毫秒）。一直被解除時，會再把麥克風音量固定在 0。所有已靜音的麥克風都會看守，不只目前使用的那一個。
- **麥克風跟著輸出裝置切換**（預設關閉）：關閉時，把輸出換成耳機不會改變麥克風；macOS 自動把麥克風換成耳機的也會改回原本的麥克風。開啟時，選擇耳機等輸出裝置會一併改用它自己的麥克風（以裝置 ID 或藍牙位址精準比對）。
- **新裝置預設 0% 並靜音**（預設開啟）：第一次連接的喇叭或麥克風會先設為 0% 並靜音；FreeAudio 第一次執行時已連接的裝置、以及之前見過的裝置不受影響。
- **設定視窗**：從選單列面板的「設定…」開啟；FreeAudio 已在執行時再次開啟 App（Finder、Spotlight、Launchpad）也會打開設定，選單列圖示被收起來時可以用這個方式。
- **記住聲音設定**：記住輸出與輸入裝置、各裝置的音量和靜音，FreeAudio 啟動時自動恢復；開啟「登入時啟動」就能在重新開機後自動恢復。可以在設定視窗關閉。
- **按應用音量**：每個 App 0–200%、靜音、左右平衡與等化器。瀏覽器、Electron 等 App 的輔助程序會歸到同一個 App 底下。
- **每個 App 的輸出裝置**：把 App 的聲音送到指定裝置，或跟隨系統預設。
- **多輸出**：把單一 App 同時送到多個裝置。
- **全局多輸出**：把系統預設裝置上的所有聲音鏡像到其他裝置，可以把個別 App 排除在外。
- **輸出裝置等化器與平衡**：套用到該裝置上播放的所有聲音。
- 設定按 App（bundle ID）與裝置（UID）記住，下次開啟 App 時自動套用。
- **等化器**：沿用「音樂」App 的規格，10 段（32 Hz–16 kHz）、每段與前級擴大都是 ±12 dB。22 組內建預設集的名稱和數值都直接取自「音樂」App 本身，沒有自行調整（見下方「等化器來源」）。
- **介面語言**：繁體中文、日文、英文，預設跟隨系統。可以在面板右上角的地球圖示或設定視窗裡即時切換，不用重新開啟。
- **自動更新**：從 GitHub releases 檢查新版本，啟動時與之後每 6 小時檢查一次，每個新版本只通知一次；也可以在設定視窗的「軟體更新」手動檢查。只安裝同一個開發團隊簽署、版本也和 release 標示相符的 App，更新完自動重新開啟。正式版只收正式版；打開「接收測試版」會收到每次推送到 main 的快照。App 要放在可以寫入的資料夾（例如「應用程式」）才能自動更新。

## 建置與執行

需要 macOS 26 以上、Xcode 26 以上。

```bash
scripts/build-app.sh          # 產生 build/FreeAudio.app（Apple silicon 與 Intel 通用）
cp -R build/FreeAudio.app /Applications/
open /Applications/FreeAudio.app
```

腳本會自動使用鑰匙圈裡的 Apple Development 憑證簽署。沒有憑證時改用 ad-hoc 簽署，每次重新建置後 macOS 都會再詢問一次權限，也無法自動更新。版本號由 `scripts/version.sh` 依 git 紀錄決定（見下方「發布」）。

從 GitHub 下載的 App 沒有經過公證，第一次開啟時 macOS 會擋下來，到「系統設定 › 隱私權與安全性」按「強制打開」即可。之後的更新由 FreeAudio 自己下載，不會再被擋。

FreeAudio 需要「系統音訊錄製」權限。在面板或設定視窗按「允許存取…」，然後在系統對話框中選擇「允許」；第一次調整 App 時也會自動詢問一次。還沒回答過之前，FreeAudio 不會出現在「系統設定 › 隱私權與安全性」的清單裡。如果對話框沒有出現，打開隱私權設定，在「系統音訊錄製」清單下方按「＋」加入 FreeAudio.app。之前按過「不允許」的話，到同一個清單把 FreeAudio 的開關打開即可。開啟「登入時啟動」前，建議先把 App 放進「應用程式」資料夾。

`swift run` 也能執行，但權限會算在終端機上，建議用打包好的 App。

## 測試

```bash
swift test
```

測試涵蓋等化器頻率響應、音量與平衡、限幅器、NaN／Inf 防護、聲道對應、設定檔解碼，以及三種語言的字串是否齊全、切換語言是否立即生效。更新的部分涵蓋版本比較（只和同一個通道比、比 build code 不比名稱）、GitHub release 的解析、下載檔的 SHA-256 與大小，以及簽署檢查：沒有簽署、ad-hoc 簽署、其他團隊簽署、簽署後被改過，或版本和 release 不符的 App 都不會被安裝。

## 發布

`.github/workflows/release.yml` 沿用 DPIP 的命名與發布規則：

- **每次推送到 main** 發布一個快照，是 GitHub 上的 pre-release，tag 就是它的名稱（例如 `26w39a`）。
- **推送 `v<yy>.<n>` tag** 發布正式版，例如 `git tag v26.1 && git push origin v26.1`。

| | 正式版 | 快照 |
| --- | --- | --- |
| 名稱 | `26.1` | `26w39a`：年、ISO 週（台北時間）、當週第幾個 |
| `CFBundleShortVersionString` | `26.1` | 它之後的正式版，例如 `26.2` |
| `CFBundleVersion`（build code） | `126000042` | `126000043` |

build code 是 `1`、兩位數年份、今年第幾個 commit，只會往上長。App 只用它判斷哪個版本比較新，而且只和同一個通道比（正式版比正式版、快照比快照）；它寫在每個 release 內容最後的 `<!-- freeaudio-build: … -->` 註解裡。release 內容由 `scripts/notes.sh` 從 commit 的條目行產生，格式見 [commit.md](commit.md)：快照列出上一個版本之後的變更，正式版列出上一個正式版之後的全部變更。

CI 需要兩個 repository secret，用和本機建置相同的 Apple Development 憑證簽署。已安裝的 FreeAudio 只接受同一個團隊簽署的更新，換了憑證 macOS 也會重新詢問音訊權限。

| Secret | 內容 |
| --- | --- |
| `APPLE_DEV_CERT_BASE64` | 從「鑰匙圈存取」的「我的憑證」匯出的 .p12（含私鑰），再用 `base64 -i FreeAudio.p12 \| pbcopy` 轉成文字 |
| `APPLE_DEV_CERT_PASSWORD` | 匯出時設定的密碼 |

App 用 GitHub 的公開 API 檢查更新，所以 repository 要公開，更新才會運作。

## 運作方式

FreeAudio 只處理你改過設定的 App，其他聲音照常直接送到硬體。

- 每條「路由」是一個 process tap 加上一個私有 aggregate device：tap 擷取 App 的聲音並讓原本的輸出靜音，FreeAudio 在 IO 回呼裡套用音量、平衡、等化器與限幅器，再輸出到目標裝置。
- 跟隨系統輸出的 App 只擷取送往該裝置的聲音；指定輸出裝置時則擷取 App 的全部聲音。
- 輸出裝置等化器用一條排除 FreeAudio 自己與其他音訊工具的全域 tap，所以不會產生回授。
- aggregate device 設定為等待音訊才啟動，App 停止播放 15 秒後路由會回到待命狀態，讓輸出裝置可以休眠。
- 如果 tap 在 App 播放中持續只給出靜音，路由會自動重建一次。
- 輸出裝置本身是 aggregate（例如「多重輸出裝置」）時，會改用它的成員裝置組成路由。

| 檔案 | 內容 |
| --- | --- |
| `AudioController.swift` | 狀態、裝置與程序監聽、決定需要哪些路由 |
| `AudioRoute.swift` | tap 與 aggregate device 的建立、更新與拆除 |
| `DSP.swift` | 即時音訊處理：等化器、增益、限幅器、聲道對應 |
| `Devices.swift`、`Processes.swift` | 裝置清單、音量與靜音、把程序歸到 App |
| `Settings.swift` | 設定模型、等化器預設集、儲存 |
| `TrayView.swift`、`Components.swift`、`SettingsView.swift` | 選單列面板、共用元件（卡片、滑桿、等化器曲線）與設定視窗 |
| `Localization.swift` | App 內語言切換與字串查詢 |
| `Update.swift`、`Updater.swift` | 版本資訊、GitHub release 的比較、下載、驗證與替換 |

## 介面

依照 macOS 26 的人機介面指南：音量、平衡與等化器都使用系統原生的滑桿（平衡從中央填色、App 音量在 100% 有刻度），開關、選單、設定視窗也都是系統元件。Liquid Glass 只會出現在系統元件本身（例如拖曳中的滑桿），內容區不加自訂卡片或玻璃效果。每個靜音按鈕都有包含對象名稱的輔助使用標籤，VoiceOver 可以分辨是哪個裝置或 App。

## 等化器來源

- 頻段與範圍：「音樂」App 的 AppleScript 字典（`/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`）列出 10 個頻段 32 Hz、64 Hz、125 Hz … 16 kHz，每段與前級擴大都是 −12 dB 到 +12 dB。
- 預設集數值：「音樂」App 存在 `~/Library/Preferences/com.apple.Music.eq.plist`（`eqps:129:EQPresets`，單位 0.01 dB）。22 組全部照抄；所有內建預設集的前級擴大都是 0 dB。
- 預設集名稱：取自「音樂」App 的在地化字串。新版「音樂」把 Bass Booster 等五組改名為「增加低音」「減少低音」「增加高音」「減少高音」「增加人聲」，這裡跟著用新名稱。
- 濾波器：「音樂」App 沒有公開它的濾波器形狀，FreeAudio 每段使用一個八度寬的 peaking 濾波器（Audio EQ Cookbook），單段在中心頻率的增益與設定值一致，相鄰頻段會疊加。

## 已知限制

- 不能和其他 tap 類的音訊工具（BetterAudio、SoundSource、FineTune 等）同時使用，否則聲音會被處理兩次或互相干擾。FreeAudio 偵測到時會在面板上提示。
- 瀏覽器所有分頁共用同一個音訊程序，所以只能整個瀏覽器一起調整。
- 經過 FreeAudio 處理的聲音會多一小段緩衝延遲。
- macOS 的語音服務（`com.apple.CoreSpeech`）在內建喇叭播放時會解除內建麥克風的靜音。FreeAudio 會立即重新靜音，但 Siri 這類語音處理可能不理會裝置的靜音，所以「嘿 Siri」仍可能聽得到。要完全避免，請在「系統設定 › Siri」關閉聆聽。
