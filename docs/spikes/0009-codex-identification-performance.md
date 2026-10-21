# 驗證報告 09：Codex 識別的效能與視窗切換

日期：2026-10-21；Codex 26.1007.71326。延續 [報告 08](0008-codex-window-routing-research.md)。本次仍是研究，沒有啟用 Hintlet 的 Codex 對話綁定或 AI 便利貼。

## 速度可以改善，但不等於可以背景輪詢

原型的選單操作含 300 ms 與 200 ms 固定等待。改成等選單實際出現，且只搜尋外殼、標頭與 portal 選單，略過側欄及訊息面板後，完整流程已測到 **210、215、220 ms，中位數 215 ms**，三次都取得預期 thread UUID。

原型的 `elapsedMilliseconds` 只涵蓋選單開始至結果檢查，不包括前置搜尋與最後還原，不能直接拿它與新數字當作同一測量範圍。新增的 `totalProbeMilliseconds` 包含整個 `run()`，包括前景／視窗檢查、搜尋、剪貼簿備份、選單操作、結果檢查及 defer 還原，不含程序啟動或 Swift 編譯。重測使用已編譯的工具，輸出在 `build/DerivedData/Probe`。

[匿名化的三次結果](fixtures/CodexLink/optimized-timings.json) 直接取自工具 stdout，不含原始 UUID、標題或訊息。`windowNumber` 是當次程序的暫時視窗編號，不能當成跨重啟的對話識別。

這表示 0.7 秒不是不可避免的讀取成本；但每次切換都打開選單並使用系統剪貼簿，仍會干擾操作。不能因此把它放進背景 Timer。

### 工具變更

[`codex-conversation-link-probe.swift`](../../Tools/codex-conversation-link-probe.swift) 改用最長 1.2 秒的條件等待，每次只在尚未找到項目時重查，不再固定睡 500 ms。搜尋有 5,000 節點上限；加入原生 window-server number 的前後核對，使用 App 已採用的 `_AXUIElementGetWindow`。

稀疏搜尋是根據這一版常見單面板外殼的效能實驗：chat header 與 portal menu 在訊息面板外。它略過整個 `*-chat-panel` 子樹，**因此不能證明內部不存在另一個巢狀面板**。工具仍只適用受控單面板研究；多面板正確性沒有因為速度測試而成立。

## 真正的雙視窗測試

這次釐清了報告 08 的疑點：Codex 的 `AXWindows` 在實測中只回報焦點視窗，但 window server 的資料能看到兩個同時可見的內容視窗。原視窗為 107，File → New Window 建立的視窗為 3008；另有低高度的工具／標題列視窗，不算內容視窗。

因此，`AXWindows.count == 1` 不代表只有一個 native window；AX 參照改變也不能單獨證明新建或關閉了視窗。跨顯示器 AX hit-test、模擬標題列點擊及 ⌘` 未成功切到預期視窗，本次不據此執行任何關閉操作。

改用原生 Window 選單，僅依兩個視窗列的勾選狀態切換；沒有以對話標題判斷 ID。

| 案例 | 結果 |
|---|---|
| 新建空白視窗 | 73 ms 拒絕：沒有唯一 `Chat actions`；沒有沿用原視窗的 thread |
| 切回原對話 A | UUID 符合預期，完整流程約 255 ms |
| 測試視窗顯示既有對話 B | UUID 符合 B，完整流程約 231 ms |
| 由 B 視窗切回仍顯示 A 的原視窗 | UUID 符合 A，完整流程約 226 ms |
| 完成清理 | 確認焦點 window-server number 為本次建立的 3008，且原 107 仍存在，才關閉 3008；恢復原對話 A |

B 是先前同名測試對話之一；不同 UUID 由已知測試 ID 比較，不使用標題配對。測試期間曾嘗試在側欄導航到已知標題，但沒有找到符合列，因此沒有執行該導航；成功的 B 測試由 deep link 導航後重新驗證。

## 競態：一個有拒絕，一個還不能算通過

跨 native window 測試使用子程序握手：先確認 getter 已保存 A 的視窗、panel 與剪貼簿狀態，開始取值，再等 30 ms 由原生 Window 選單切到 B。結果回傳 `Copy submenu unavailable`，完整流程約 1,303 ms，沒有接受過期 ID。這是遇到失效時等到截止才拒絕的時間，不是正常成功延遲。

第一次未同步的測試在子程序啟動前就已切到 B，所以正常取得 B，不能把「與原先預期 A 不同」當成誤判；因此才加入握手重測。

同一視窗也做了握手後 30／120 ms 送出 B deep link 的測試；兩次仍回傳 A，約 226／223 ms。**未記錄畫面實際從 A 變成 B 的時刻，不能證明切換已發生於讀取結束前，也不能把這兩次當成競態通過。** [原始匿名結果](fixtures/CodexLink/same-window-navigation-requests.json) 的 `switchDelayMilliseconds` 是送出導航要求的時間，不是實際 route 更新時間。這仍是正式整合前要補的測量。

## 為什麼不能以 panel ID 永久快取 UUID

安裝包原始程式提供反例，不能只依「幾次切換時 ID 剛好變了」就宣稱可快取：

- `webview/assets/thread-app-shell-chrome-283504a55587.js`：`jc` 用 `React.useId()` 建立 `${N}-chat-panel`，沒有以 conversationId 建立識別。
- 同模組 `Gc` 約 70,313：更新 conversationId 時內部元件沒有 React key；`local-conversation-page` 約 36,207 的 `Gc` 使用點也沒有 key。
- `app-primary` 的 `Egt` 約 1,503,000：一般 retained thread 的祖先 key 通常包含 `local:<uuid>` scope，但 destination 分支改以 destination ID／key 區隔；停用 retention 的分支直接 render，沒有同一個 keyed wrapper。

所以 React token 可以當短期拒絕條件（變了就丟棄結果），不能當正面證明（沒變就認定 thread 沒換）。正式功能不應建立 token → UUID 的永久快取，也不能以只讀 token 的便宜輪詢宣稱解決自動追蹤。

## 再查被動檔案與原生狀態

查閱安裝包 bootstrap、main 與實際資料目錄 schema，沒有讀 cookies、認證檔、rollout、一般網頁內容或系統診斷 log。

- bootstrap `bootstrap-DOZRFVdo.js` 的 `oD` 約 420,127、`app.setPath` 約 457,417，證明目前 profile 是 `~/Library/Application Support/Codex`，不是 `ChatGPT` 或另一個 Atlas profile。`CODEX_ELECTRON_USER_DATA_PATH` 可覆寫位置。
- Codex、Default、codex-browser-app 下沒有 `Sessions` 目錄；Preferences 的 sessions 欄位只有 event_log/session_data_status，本次 schema 檢查沒有找到目前視窗 route。
- main 約 1,484,000 的 `browser-sidebar-page-states.json` 嚴格 schema 只有 browserTabId、owner conversationId 與網頁 navigation/url 等歷史狀態，沒有 windowId／visible／presented／active conversation。main 約 1,934,705 另限制只有 initial primary window 寫入，不能當每個視窗的即時對話登錄。
- `BrowserHost.sync`（main 約 1,971,900）把 activeConversationId、activeBrowserTabId 更新在記憶體；寫入檔案的 snapshot 排除了這些欄位。舊 browser partition 名稱中的 conversation ID 只是歸屬資訊，不是正在觀看的證明。
- 另外找到 PiP 路徑的 BrowserWindow ID → thread ID 記憶體 map（main `Kh` 約 455,000），透過 native sky.node 的 private XPC setter 發布選定 thread。但只在特定 PiP eligibility／layout 生效，沒有找到公開 getter 或可讀的每視窗檔案。未連線私有服務、未偽裝 peer，也未以歷史 log 當即時狀態。

## 本輪結論

已證明：主動式的對話專屬選單可以更快，且在受控環境可準確區分同名對話、兩個同時存在的不同對話視窗，也能對空白視窗及一次中途跨視窗切換拒絕。

尚未證明：無干擾的持續自動追蹤、剪貼簿寫入歸屬、多面板、所有同視窗導航競態。研究工具不等於符合原需求的正式 adapter；目前沒有找到能取代它的被動檔案訊號，也不採用標題配對或未證實的 panel 快取。

本輪驗證為探測工具的編譯、真實操作與上述精確測量；沒有改 Hintlet App／Core 執行行為，未操作正式 notes.json，未呼叫摘要後端。先前完整 Core 402 測試與 Debug 建置的結果仍只是原功能基線，不宣稱為尚未實作 Codex 功能的驗證。
