<div align="center">

<img src=".github/assets/icon.png" width="128" alt="FreeAudio">

# FreeAudio

**macOS 選單列的音訊控制 —— 每個 App 都有自己的音量、輸出裝置與等化器，不用安裝任何音訊驅動。**

[![正式版](https://img.shields.io/github/v/release/ExpTechTW/FreeAudio?label=%E6%AD%A3%E5%BC%8F%E7%89%88&color=1B8A50)](https://github.com/ExpTechTW/FreeAudio/releases/latest)
[![測試版](https://img.shields.io/github/v/tag/ExpTechTW/FreeAudio?sort=date&label=%E6%B8%AC%E8%A9%A6%E7%89%88&color=orange)](https://github.com/ExpTechTW/FreeAudio/releases)
[![建置](https://img.shields.io/github/actions/workflow/status/ExpTechTW/FreeAudio/release.yml?branch=main&label=%E5%BB%BA%E7%BD%AE)](https://github.com/ExpTechTW/FreeAudio/actions/workflows/release.yml)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#下載)
[![Discord](https://img.shields.io/discord/926545182407688273?logo=discord&logoColor=white&label=Discord&color=5865F2)](https://discord.gg/5dbHqV8ees)

**繁體中文** • [English](README.en.md) • [日本語](README.ja.md)

[下載](https://github.com/ExpTechTW/FreeAudio/releases/latest) • [更新日誌](https://github.com/ExpTechTW/FreeAudio/releases) • [回報問題](https://github.com/ExpTechTW/FreeAudio/issues)

</div>

## FreeAudio 是什麼

FreeAudio 是住在選單列的 macOS 音訊工具。除了切換裝置、調整音量，還能讓每個 App 有自己的音量、輸出裝置和等化器，也能把聲音同時送到多個裝置。

它用 macOS 內建的 Core Audio process tap 處理聲音，不需要安裝虛擬音訊驅動。只有你調整過的 App 會經過 FreeAudio，其他聲音照常直接送到硬體。

## 能做什麼

| | |
|---|---|
| **輸入與輸出** | 切換喇叭與麥克風、調整音量與靜音。HDMI 螢幕這類本身沒有音量控制的裝置，也能由 FreeAudio 調整 |
| **按應用音量** | 每個 App 可以有 0–200% 的音量、靜音、左右聲道平衡與 10 段等化器，也能指定自己的輸出裝置，或同時送到多個裝置。瀏覽器、Electron App 的輔助程序會歸到同一個 App |
| **全局多輸出** | 把所有聲音同時送到多個裝置。像選 AirPlay 喇叭一樣在「輸出」勾選裝置，每個裝置各自有音量、靜音、平衡與等化器；個別 App 可以排除 |
| **等化器** | 沿用「音樂」App 的規格：10 段（32 Hz–16 kHz）、±12 dB、前級擴大，以及名稱與數值都相同的 22 組預設集 |
| **鎖定所選裝置** | 只用在 FreeAudio 選的喇叭和麥克風。接上耳機時 macOS 自動切換、或在控制中心切換，都會被改回來；所選裝置不在時，會把 macOS 改用的裝置靜音並提醒你，不會自動換到別的裝置 |
| **新裝置不出聲** | 第一次連接的喇叭或麥克風先設為 0% 並靜音，避免聲音意外外放或被收音 |
| **麥克風靜音不會自己解除** | 在 FreeAudio 靜音的麥克風，只有在 FreeAudio 解除靜音才會打開；macOS 自己解除時（例如 Siri 聆聽、通話切換裝置），會立即重新靜音。麥克風靜音或無法使用時，選單列圖示是紅色斜線麥克風 |
| **記住聲音設定** | 記住裝置、音量與靜音，重新開機後自動恢復 |
| **自動更新** | 從 GitHub 取得經 Apple 公證的更新，而且只安裝同一個開發者簽署的版本；可以選擇接收測試版 |
| **三種語言** | 繁體中文、English、日本語，預設跟隨系統，也可以在設定中切換 |

## 下載

需要 **macOS 26 以上**，Apple silicon 與 Intel 都能用。

1. 到 [Releases](https://github.com/ExpTechTW/FreeAudio/releases/latest) 下載 `FreeAudio-<版本>.zip`，解壓縮後把 FreeAudio.app 放進「應用程式」資料夾再打開。App 經過 Apple 公證，可以直接開啟。
2. 第一次調整 App 的聲音時，macOS 會詢問「系統錄音」權限，請選「允許」。也可以在選單列面板或設定視窗按「允許存取…」。
   - 對話框沒出現：打開「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」，在「僅限系統錄音」清單下方按「＋」加入 FreeAudio。
   - 之前按過「不允許」：在同一個清單把 FreeAudio 的開關打開。
3. 想在重新開機後自動恢復聲音設定，請在設定中開啟「登入時啟動」。

FreeAudio 在啟動時與之後每 6 小時檢查一次更新，有新版本時會通知你；也可以在「設定 › 軟體更新」按「立即檢查」。選單列圖示被收起來時，再次打開 FreeAudio（從 Finder 或 Spotlight）就會顯示設定視窗。

### 正式版與測試版

| | 名稱 | 發布時機 |
|---|---|---|
| 正式版 | `26.1`：年份．第幾版 | 手動發布 |
| 測試版 | `26w39a`：年份、第幾週、當週第幾個 | 每次推送到 `main` 自動發布；未經審查，可能有問題 |

想搶先試用，請在「設定 › 軟體更新」開啟「接收測試版」。正式版只會更新到正式版，測試版只會更新到測試版。選單列面板底部會顯示目前的版本：測試版是橘色標籤，正式版是綠色標籤。

## 已知限制

- 不能和其他同類的音訊工具（BetterAudio、SoundSource、FineTune 等）同時使用，否則聲音會被處理兩次；FreeAudio 偵測到時會在面板上提醒。
- 瀏覽器的所有分頁共用同一個音訊程序，只能整個瀏覽器一起調整。
- 經過 FreeAudio 處理的聲音會多一點點延遲。
- Siri 的語音處理可能不理會麥克風靜音。要確保 Siri 聽不到，請在系統設定中關閉 Siri 的聆聽。

## 參與開發

需要 macOS 26 以上與 Xcode 26 以上。

```bash
git clone https://github.com/ExpTechTW/FreeAudio.git
cd FreeAudio
git config core.hooksPath .githooks   # 提交時檢查 commit 訊息
swift test                            # 跑測試
scripts/build-app.sh                  # 建置 build/FreeAudio.app
open build/FreeAudio.app
```

- `scripts/build-app.sh` 用鑰匙圈裡的憑證簽署：優先 Developer ID Application，其次 Apple Development。都沒有時改用 ad-hoc 簽署，每次重新建置後 macOS 都會再詢問權限，也無法自動更新。
- `swift run` 也能執行，但權限會算在終端機上，建議用打包好的 App。
- commit 訊息就是更新日誌，格式見 [commit.md](commit.md)，由 git hook 與 CI 檢查。

### 運作方式

FreeAudio 只處理你改過設定的 App 與裝置。每一條「路由」是一個 process tap 加上一個私有的 aggregate device：tap 擷取 App 的聲音並讓原本的輸出靜音，FreeAudio 在 IO 回呼裡套用音量、平衡、等化器與限幅器，再輸出到目標裝置。

- 跟隨系統輸出的 App 只擷取送往該裝置的聲音；指定了輸出裝置的 App 則擷取它全部的聲音。
- 輸出裝置的等化器與全局多輸出，用的是排除 FreeAudio 自己與其他音訊工具的 tap，所以不會產生回授。
- 路由在有聲音時才啟動，App 停止播放 15 秒後回到待命，讓輸出裝置可以休眠。
- 輸出裝置本身是 aggregate（例如「多重輸出裝置」）時，改用它的成員裝置組成路由。

| 檔案 | 內容 |
|---|---|
| `AudioController.swift` | 監聽裝置與程序，決定需要哪些路由 |
| `RoutePlan.swift`、`MultiOutput.swift` | 依設定算出路由；全局多輸出的勾選規則 |
| `AudioRoute.swift`、`DSP.swift` | tap 與 aggregate device；即時處理（等化器、增益、限幅器、聲道對應） |
| `Devices.swift`、`DeviceLock.swift`、`MicrophoneHold.swift` | 裝置、音量與靜音；鎖定所選裝置；麥克風靜音保護 |
| `Processes.swift`、`Permission.swift` | 把程序歸到 App；系統錄音權限 |
| `Settings.swift` | 設定模型、等化器預設集與儲存 |
| `TrayView.swift`、`SettingsView.swift`、`Components.swift` | 選單列面板、設定視窗與共用元件 |
| `Update.swift`、`Updater.swift` | 自動更新：比較版本、下載、驗證與替換 |
| `Localization.swift` | 介面語言 |

### 等化器來源

- 頻段與範圍：「音樂」App 的 AppleScript 字典（`Music.app/Contents/Resources/com.apple.Music.sdef`）列出 10 段 32 Hz–16 kHz，每段與前級擴大都是 −12 到 +12 dB。
- 預設集：22 組的數值全部照抄 `~/Library/Preferences/com.apple.Music.eq.plist`（`eqps:129:EQPresets`，單位 0.01 dB）；名稱用「音樂」App 的在地化字串，包含新版改名的「增加低音」等五組。
- 濾波器：「音樂」App 沒有公開濾波器形狀，FreeAudio 每段用一個八度寬的 peaking 濾波器（Audio EQ Cookbook）。

### 發布

沿用 DPIP 的規則：推送到 `main` 會自動發布測試版，推送 `v<yy>.<n>` tag（例如 `v26.1`）會發布正式版。每個版本都以 Developer ID 簽署、經 Apple 公證；更新日誌由 commit 的條目行自動產生（見 [commit.md](commit.md)），並公告到 Discord。

## 授權

[FreeAudio Public License](LICENSE)。**這是 source-available 授權，不是開放原始碼授權** —— 原始碼公開可閱讀、可貢獻，但禁止商業使用，也禁止用來做出與 FreeAudio 競爭的產品。完整條款見 [LICENSE](LICENSE)。
