# 驗證報告 03：浮動面板行為

日期：2026-10-14　macOS 27　單一內建螢幕（3024×1964 Retina，1512×982 點）

面板設定（`App/NotePanel.swift`）：
- 樣式：無邊框、`.nonactivatingPanel`
- 層級：`.floating`
- 集合行為：`[.canJoinAllSpaces, .fullScreenAuxiliary]`
- 其他：`hidesOnDeactivate = false`、`canBecomeKey = true`

測試方式：用 TextEdit 開一份測試檔，以 AX 的 `AXFullScreen` 切成全螢幕；再用 System Events 送出 ⌘⌥N、打字、Esc、⌃←／⌃→，以及按住 ⌘ 再按 Tab 時截圖。
- 前景 App：用 `lsappinfo front` 取得。
- 視窗是否在畫面上：用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 確認。

## 結論

| 項目 | 結果 |
|---|---|
| 在另一個 App 的全螢幕空間按 ⌘⌥N | ✅ 便利貼出現在全螢幕空間上，可以立刻打字。當時的輸入法是中文，打出的字呈現組字中的底線狀態，代表輸入法有作用在便利貼上；沒有實際測選字。啟用 Hintlet 沒有把畫面切離全螢幕空間 |
| 切換桌面空間（全螢幕 ↔ 一般桌面） | ✅（浮動便利貼）兩張便利貼在兩個空間都在畫面上，位置不變。綁定工作內容的便利貼也用同樣的面板設定，但要由引擎依前景決定顯示或隱藏；這部分在 ticket 05／07 驗證 |
| ⌘⌥N 後按 Esc | ✅ 前景交還原本的 App（TextEdit），仍停在全螢幕空間 |
| 點一下既有便利貼再打字 | ✅ 前景仍是 TextEdit，字打進便利貼。不必啟用 Hintlet 也能輸入 |
| ⌘Tab | ✅ 前景是 TextEdit 時按 ⌘Tab，切換器中沒有 Hintlet（accessory App），切換器蓋在便利貼上方，屬正常。⌘⌥N 後 Hintlet 在前景時的 ⌘Tab 沒測 |
| 兩個螢幕的座標換算 | ✅ 換算寫成核心邏輯並以測試涵蓋（見下方）。ticket 05 接上外接 2560×1440（右側、往下錯開）後實機驗證：建立位置、視窗換螢幕、外接螢幕全螢幕都正確。上方／左側排列待 ticket 13 |

## 編輯時的「隱藏 → 重新顯示」循環

- **點一下便利貼編輯**：不會改變前景 App，不會觸發循環。
- **按 ⌘⌥N 新增**：Hintlet 會短暫成為前景 App（ticket 01 的偏離，使用者已同意）。
  - ticket 01 時試過不啟用 App：`makeKeyAndOrderFront` 讓面板成為 key window，但鍵盤輸入不會送到非啟用中的 App，必須先點一下。所以用快捷鍵新增時，仍然需要啟用。
  - **規則（交給 ticket 05／07 實作並測試）**：工作內容的偵測要忽略「前景變成 Hintlet 自己」這件事，沿用上一個工作內容。這樣編輯中的便利貼不會因為前景改變而被藏起來。這條規則要放在引擎（切面 A），用測試涵蓋。
  - 按 Esc 時，前景會回到原本的 App（已測），工作內容不變，不會重新顯示。改為點別處讓便利貼失去焦點時，前景會直接變成被點的 App，這個情況沒測，交給 ticket 05 的手動驗證。

## 座標換算（多螢幕）

- **兩套座標**：
  - AX 的 `AXPosition`／`AXSize` 和 CGWindowList：原點在主螢幕左上，y 向下。
  - AppKit 的 `NSWindow`／`NSScreen`：原點在主螢幕左下，y 向上。
- **換算**：兩套座標都涵蓋所有螢幕，所以只需要主螢幕高度：`appKitY = 主螢幕高度 − (topLeftY + 高度)`，x 不變。主螢幕是 `NSScreen.screens[0]`，不是 `NSScreen.main`，後者是目前有焦點的螢幕。
- **實作與測試**：實作在 `HintletCore/ScreenCoordinates.swift`，測試涵蓋主螢幕、位在上方的副螢幕（y 為負）、位在左側的副螢幕（x 為負）。
- **建立位置**：便利貼依游標所在螢幕夾進可視範圍。ticket 01 有單元測試用假的螢幕資料涵蓋「游標在副螢幕選單列」，但沒有在實機上驗證。
- **換算的範圍**：測試只涵蓋座標翻轉。判斷視窗在哪個螢幕、視窗換螢幕時便利貼怎麼跟著走，屬於 ticket 05 的引擎測試。

## 限制與待驗證

- **兩個螢幕**：不同解析度、不同排列的實機驗證，留到接上外接螢幕時，放進驗收清單（ticket 13）。
- **模擬按鍵**：用 `CGEvent` 直接送 ⌘⌥N 不會觸發 Carbon 熱鍵（今天實測），用 System Events 送才會。這是測試工具的差異，實際按鍵沒有這個問題。往後的自動驗證改用 System Events。
- **全螢幕 App 的 Esc**：使用者在全螢幕 App 中結束編輯後，若再按一次 Esc，會送到該 App（TextEdit 會因此退出全螢幕）。這是正常行為，不是 Hintlet 的問題。
