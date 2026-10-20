# 驗證報告 05：讀出瀏覽器目前的網址

日期：2026-10-18　Safari（macOS 27 內建）　Chrome 已安裝但未執行

探測工具：[`Tools/browser-ax-probe.swift`](../../Tools/browser-ax-probe.swift)（`snapshot`、`watch <秒>`）。只讀不寫：不設定 `AXManualAccessibility`／`AXEnhancedUserInterface`，不送 AppleScript，也不需要新的權限（用的是 Hintlet 本來就有的輔助使用權限）。預設把網址遮蔽成 `scheme://<host-N>/<path-N>`。

這次只做了不打擾使用者的唯讀探測：使用者正在用這台 Mac，Safari 只開著一個起始頁視窗，Chrome 沒有執行。沒有替使用者開網頁、切分頁或啟動 Chrome，所以下面多數項目留待手動驗證。

## 已驗證

- **Safari 起始頁**（唯一的視窗，`AXFocusedWindow` 在 Safari 不在前景時讀不到，改讀 `AXMainWindow`／`AXWindows`）：
  - 視窗 subrole 是 `AXDialog`，`AXIdentifier` 是 `SafariWindow?IsSecure=false&UUID=<uuid>`，`AXDocument` 為空，標題 10 個字元（Start Page）。
  - 視窗裡**沒有** `AXWebArea`：起始頁是原生畫面，不是網頁。
  - 網址列是 `AXTextField`，`AXIdentifier` = `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD`，`AXDescription` = `smart search field`，值是空字串。
  - 所以「沒有網頁區域＋網址列是空的」＝起始頁／新分頁，App 據此提示並提供「改貼在這個視窗」。
  - Safari 的 `AXEnhancedUserInterface` 是 0，`AXManualAccessibility` 不存在；不必開任何東西就讀得到上面這些。
- **讀取成本**：起始頁視窗寬度優先走訪 237 個節點（不進網頁區域）約 32ms，找網址列約 24ms。實作把走訪上限設為 800 個節點，並在找到網頁區域後不再深入；輪詢只讀快取網頁區域的 AXURL。

## 待手動驗證（用 `swift Tools/browser-ax-probe.swift safari|chrome snapshot`、`watch 20`）

- **Safari 一般網頁**：網頁區域是否只有一個、尺寸非零，`AXURL` 是否為完整網址；網頁區域的 `AXTitle` 是否是網頁標題；視窗的 `AXDocument` 是否也帶網址（若有，可當更便宜的來源）。走訪節點數與耗時（分頁多時）。
- **Safari 切換分頁**：會收到哪些通知（預期 `AXTitleChanged`），舊分頁的網頁區域是否從樹上移除（實作每次 refresh 都重新找，不沿用舊元素）。
- **同一分頁內換網址**（YouTube 點下一部影片）：`AXURL` 改變與通知的時間差；實作每 0.5 秒讀一次快取元素的 `AXURL` 補漏。
- **Safari 私密瀏覽視窗**：`AXIdentifier` 的 `IsSecure` 是否就是私密瀏覽（也可能是指 HTTPS），或有其他可辨識的屬性。App 已把 `IsSecure=true` 當作私密視窗的線索接上（`WebPages.isPrivateWindow`，只給視窗範圍、網址不寫進檔案），但還沒在私密視窗與一般 HTTPS 網頁上實測；若它代表 HTTPS，要換線索。
- **Chrome**：不開啟完整輔助使用樹時，`AXWebArea` 與其 `AXURL` 是否讀得到（Chromium 偵測到輔助使用 API 呼叫時可能會自動開啟部分樹，第一次可能要等一下）。若讀不到，要比照 Claude 先徵得同意再設 `AXManualAccessibility`，並量開啟前後的記憶體與 CPU。新分頁的網頁區域網址預期是 `chrome://newtab/`；無痕視窗的辨識方法——App 目前用視窗標題結尾的「(Incognito)」或工具列上寫著「Incognito／無痕模式」的按鈕當線索，待實測。
- **Arc、Edge 等 Chromium 瀏覽器**：Chrome 的方法若直接可用，把 bundle ID 加進 `BrowserPages.bundleIDs`。

## 實測（2026-10-18，使用者的 Mac、英文介面，唯讀）

- **Safari 一般網頁**：一個網頁區域，`AXURL` 是完整網址（https）。在 Safari 一般視窗貼的便利貼綁到網頁（YouTube），切分頁會收起、回來出現（使用者確認）。
- **Safari 的 `IsSecure`**：只代表網頁是 HTTPS。一般視窗開 HTTPS 網頁是 `IsSecure=true`；一般與私密視窗的起始頁都是 `false`。先前把它當私密視窗的線索是錯的，Safari 的網頁便利貼因此全落到整個視窗——已改掉。
- **Safari 私密視窗**：網址列（`WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD`）的 `AXDescription` 是「smart search field in a private window」（一般視窗是「smart search field」）；起始頁的視窗標題是「Start Page, Private Browsing」，開了網頁是「<頁面標題>, Private Browsing」。App 改以網址列說明裡的「private／私密／隱私」辨識。
- **Chrome 無痕視窗**：視窗標題結尾「(Incognito)」，工具列有標題為「Incognito」的按鈕。兩個線索都對。
- **Chrome 一般視窗**：不開完整輔助使用樹時找不到網頁區域，網址列也沒有 `AXIdentifier`；Chrome 的便利貼綁在視窗並提示（使用者確認）。
- **私密視窗的便利貼**：Safari 私密與 Chrome 無痕各貼一張，都綁在視窗，`notes.json` 沒有網址。但視窗綁定原本會存視窗標題（即頁面標題，如「YouTube, Private Browsing」）——已改成私密視窗不存標題。

## 支援矩陣（目前）

| 瀏覽器 | 讀網址 | 新分頁 | 內部頁面 | 私密視窗 |
|---|---|---|---|---|
| Safari | 網頁區域 AXURL（已驗證） | 已驗證：無網頁區域＋網址列空白 | `safari-resource:` 等非 http(s) → 降級（待驗證） | 網址列說明「in a private window」→ 視窗（已驗證） |
| Chrome | 不開完整樹讀不到（已驗證）→ 視窗 | `chrome://newtab` 等（待驗證） | `chrome://settings` 等 → 降級 | 標題或按鈕「Incognito」→ 視窗（已驗證） |
| Arc、Edge、Brave | 未支援 | — | — | — |

## 不採用

- **AppleScript 讀目前分頁網址**：需要「自動化」權限，每個瀏覽器各問一次。只在 AX 方法確定不行時才考慮。
- **讀網址列的值當網址**：Safari 平常只顯示網域、Chrome 會省略 `https://` 與 `www.`，使用者在網址列打字時值也會變，不能當作頁面的身分。只用來分辨起始頁（空白）。
