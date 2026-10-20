# 驗證報告 02：Claude 對話識別

日期：2026-10-14　Claude 桌面 App 2.37337.1　macOS 27

探測工具：[`Tools/claude-ax-probe.swift`](../../Tools/claude-ax-probe.swift)（`snapshot`、`links`、`watch`、`messages`）
切面 B 素材：[`Packages/StickyContextCore/Tests/StickyContextCoreTests/Fixtures/ClaudeAX/`](../../Packages/StickyContextCore/Tests/StickyContextCoreTests/Fixtures/ClaudeAX/)，探測工具預設把對話 ID 換成假 UUID、對話名稱換成「範例對話」（`--raw` 才保留原值）。每份快照都記錄焦點元素，以及從它往上找到的最近網頁區域。

## 錄到的頁面

| 快照 | 網頁區域 AXURL | 網頁區域標題 | 應判定為 |
|---|---|---|---|
| `chat-conversation` | `/chat/<uuid>` | `<對話名稱> - Claude` | Chat 對話 |
| `cowork-session` | `/cowork/local_<uuid>` | `<任務名稱> - Claude` | Cowork session |
| `code-session` | `/epitaxy/local_<uuid>` | `<session 名稱> - Claude Code` | Code session |
| `chat-new` | `/new?mode=chat` | `New session - Claude` | 新對話草稿 |
| `cowork-new` | `/new`（`/task/new` 會被導到這裡） | `New task - Claude` | 新對話草稿 |
| `code-home` | `/epitaxy`（`claude://code/new` 也落在這裡） | `Claude` | 新對話草稿 |
| `settings-over-new` | `/new#settings/general` | `New session - Claude` | 設定開啟中：暫時隱藏，不可新貼 |
| `projects` | `/projects` | `Projects - Claude` | 降級為視窗範圍 |
| `chat-deleted-redirects-to-new` | `/new` | `New session - Claude` | 新對話草稿（開不存在的對話會被導回新對話草稿） |
| `synthetic-two-web-areas` | 兩個網頁區域，其一尺寸為零 | — | 合成素材：依焦點元素判斷 |
| `synthetic-unexpected-url` | `/chat/not-a-uuid` | — | 合成素材：降級 |

## 已驗證

- **判斷規則**：依 spec「由焦點元素向上找最近的網頁區域」。實測可行：每份快照的焦點元素（多半是輸入框）往上都找得到網頁區域，網址與頁面一致。在專案頁沒有輸入框，焦點就是網頁區域本身。每次快照的焦點視窗都只有一個網頁區域，尺寸等於視窗內容區，所以「焦點視窗中唯一、尺寸非零的網頁區域」可以當備用規則。兩條規則都找不到、或結果互相矛盾時，就無法判斷，一律降級。
- **網址格式**符合 ADR-0001，另外補兩點：
  - Chat 草稿是 `/new?mode=chat`，Cowork 草稿是 `/new`。
  - 設定頁沿用底下頁面的路徑，只加 `#settings/…`。spec 目前寫「設定頁 → 降級為視窗範圍」。照實測結果，有兩種做法：比對 fragment 中的 `#settings` 後降級，或在設定開著時暫時不顯示。**使用者已選擇「暫時不顯示」，spec 已更新。**
- **標題**：三種對話的網頁區域標題都是「對話名稱 + 後綴」：
  - Chat：「 - Claude」。
  - Cowork：「 - Claude」。
  - Code：「 - Claude Code」。

  Chat 的標題不必另找來源。Cowork 和 Code 的本機 session 檔（`local-agent-mode-sessions/…/local_<id>.json`、`claude-code-sessions/…/*.json`）都有 `title` 與 `isArchived` 欄位，符合 spec「Cowork／Code 讀本機 session 檔的標題」。對話不在畫面上時也讀得到，列表顯示仍以 session 檔為準。
- **切換延遲**：切換對話時，`AXFocusedUIElementChanged`（與 `AXTitleChanged`）通知和 AXURL 改變發生在同一個 5ms 內。輪詢間隔是 20ms。
  - 「收到通知就讀網址」幾乎沒有延遲。
  - 低頻輪詢（0.5–1 秒）只用來補漏。
- **Code 的 `lastFocusedAt`**：切到 Code session 後約 3 秒才寫入。它只適合做事後校正，不能當切換訊號。
- **讀取成本**：找網頁區域約 1ms；之後讀快取元素的 AXURL，平均每次 0.03ms。

## 不確定

- **完整輔助使用樹的資源影響**：探測時 Claude 一直開著，無法在同一次執行中比較「開／關」。這個 session 就跑在 Claude 裡，重開 Claude 會中斷工作。目前只量得到「開啟後」的數字：renderer 約 1.1GB RSS；這次 session 持續輸出時，CPU 約 10%。要做對照，可以在重開 Claude 後、執行探測前，先量一次 `ps` 的數字。
- **剛開啟時樹是空的**：對 Claude 設 `AXManualAccessibility` 後，立刻讀樹可能拿到空結果（第一次探測就遇到）。等約 0.5 秒再讀就正常。實作時要在開啟後重試。
- **多視窗**：這次只有一個 Claude 視窗，沒有錄到多視窗或多個網頁區域的快照。這時判斷規則改以焦點視窗為準。真的出現多個網頁區域時，降級。
- **使用者用滑鼠點側欄切換**：上面的延遲是用 `claude://` 切換量的。這種切換會啟用 App、把焦點移到輸入框，通知可能比平常多。這次沒有模擬點擊，以免干擾。點側欄的延遲要在 ticket 07 手動驗證時用 `watch` 再量一次；在那之前，低頻輪詢是保底。
- **設定開在既有對話上**：`claude://…/chat/<id>#settings/general` 不會打開設定，所以沒錄到「對話上開著設定」的快照，只錄到開在新對話草稿上的。ticket 07 手動補錄。

## 不可行

- 側欄的對話清單沒有帶 AXURL 的連結，`links` 只找到 `/new`、`/downloads`。無法從 AX 列出所有對話，只能辨識目前顯示的那一個。這不影響 v1。
