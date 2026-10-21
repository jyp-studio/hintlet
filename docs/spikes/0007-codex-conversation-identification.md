# 驗證報告 07：Codex 對話識別的可靠性門檻

日期：2026-10-21。調查對象：本機 Codex `26.1007.71326`（`/Applications/ChatGPT.app`，bundle ID `com.openai.codex`）。

狀態：**尚未找到已驗證、可由 Hintlet 讀取的當前視窗 thread ID。停在識別調查，不實作名稱配對，也未啟用 Codex 對話綁定或 AI 便利貼。**

## 找到的訊號

本次只檢查安裝包程式碼、本機狀態鍵名與 SQLite schema，沒有讀 rollout 對話內容。

| 來源 | 找到什麼 | 為何還不能用來綁定 |
|---|---|---|
| Codex 側欄 DOM | `data-app-action-sidebar-thread-id`、`-active`、`-host-id`、`-kind` | 是自訂 `data-*` 屬性，不是 HTML `id`；尚未證實 macOS AX 可以讀到 |
| 目前側欄項目 | `aria-current="page"`；selection 另外記錄 | 知道哪一列 active 仍不足以取得其 thread UUID；不能拿名稱回查代替 |
| 側欄標題 DOM ID | React `useId()` 產生 | 不是 thread UUID，也不是可跨重啟識別的綁定資訊 |
| 文件初始網址 | `initialRoute` 可能含 thread ID | 一般 pane router 使用 `initialEntries`；只有特定 `persistForReload === true` 導航才更新文件網址，不能假定它跟著每次切換更新 |
| `~/.codex/state_5.sqlite` | threads 有 ID、rollout 路徑、更新／recency、archive 等欄位 | schema 沒有找到目前視窗／焦點對話對應欄位；更新或 recency 不代表正在觀看 |
| `~/.codex/.codex-global-state.json` | 視窗 bounds、許多 thread 各自的 tab routes 等鍵 | 沒有找到權威的當前視窗 → thread 映射；儲存許多 thread 的狀態不代表其中一個現在可見 |
| Deep link | 可導向指定對話 | 能開啟某 thread 不等於能查詢目前視窗的 thread |

安裝包證據位置（僅適用上述版本）：

- `webview/assets/app-shared-8340f229c2b3.js`：`sidebarThreadRow({active,hostId,id,kind,...})` 建立自訂 DOM 屬性。
- `webview/assets/app-initial-1ab6fbe93c4f.js`：使用上述屬性尋找 active row；側欄 row 的 `aria-current` 與標題的 `useId()`；文件 initial route 與 pane router 的處理。
- 主程序 `persistPrimaryWindowBounds` 只保存座標、尺寸與最大化狀態。其他記憶體內的 shortcut state 尚無可供 Hintlet 使用的穩定介面。

這是程式碼搜尋結果，不是「AX 絕對沒有可用資訊」的證明，也沒有把程式碼推測製造成真實 AX 測試素材。

## 真機 AX 驗證受阻

以獨立 Swift 程式呼叫 `AXIsProcessTrusted()`，沙箱內與外都回傳 false；沒有要求權限、沒有操作系統權限對話框。故沒有錄到 Codex 的 AX 樹，也無法確認自訂 DOM 屬性是否有任何 AX 對應。

加入可重跑的 [`Tools/codex-ax-probe.swift`](../../Tools/codex-ax-probe.swift)：

```sh
swift Tools/codex-ax-probe.swift --enable-accessibility > /tmp/codex-ax.json
```

需要在本來就有輔助使用權限的執行環境中執行。沒有權限就退出，不跳權限要求。`--enable-accessibility` 才會設定 Codex 的 `AXManualAccessibility` 並等待 1.2 秒；已開啟時可省略。

工具只記錄角色、屬性名稱、DOM ID／class、選取／焦點狀態與允許的路由網址；不讀標題、文字、描述、訊息或 rollout。UUID 以固定 namespace 的 SHA-256 前 128 位轉成假 ID，同一 UUID 在不同次執行保持相同值。網址只允許 `app://./index.html`、`app://./detached-window.html` 與 `codex://threads/<uuid>`，移除 query／fragment，拒絕帳密／port；其他網址（包括訊息中的 HTTPS 連結與 `file:` URL）不記錄。此白名單只定義安全記錄格式，不表示已驗證它們能反映當前 thread。每個視窗限制 5,000 節點與 70 層，截斷時標記 `truncated`。輸出仍應先在本機檢查，再決定是否提交為測試素材。

要驗證的不只是「找到一個 UUID」，還包括切換後立即失效／更新、同名對話、改名、新對話草稿、側欄隱藏、設定頁、多視窗與不同 host。若文件網址仍指向前一個 thread，必須拒絕該訊號，不能靠等待補救。

## 下一步與決策

優先取得真實 AX 快照並驗證切換，確認公開 AX 能否提供當前 thread ID。若最終只有名稱可用，依使用者要求先回報，等使用者決定是否接受「名稱唯一才綁定；重複／無法判斷則退回視窗」；本次沒有自行採用這個折衷。即使名稱唯一，仍須考慮重新命名與索引延遲。

找到可靠訊號後才進入 `ConversationKind`、純邏輯與真實素材測試、App adapter、刪除處理及 rollout 摘要的實作。ADR-0001 與規格的 Codex 支援狀態暫不改成已支援，也不建立宣稱已選定識別方式的 ADR。

## 本次驗證

- 探測工具通過 `swiftc -typecheck`；執行時依預期在缺少 AX 權限處退出，未取得真實快照。
- `cd Packages/HintletCore && swift test`：402 個測試通過。
- 指定 Debug `xcodebuild`：成功，Derived Data 在 `build/DerivedData`。
- 未啟動 Hintlet 測試真實便利貼，未讀寫正式 `notes.json`，未呼叫摘要後端。
