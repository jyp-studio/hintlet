# 驗證報告 08：Codex 的視窗與對話路由

日期：2026-10-21。對象：本機 Codex 26.1007.71326 安裝包，解包於 `/tmp/hintlet-codex-asar`。

本報告檢查安裝包程式碼與資料目錄項目名稱，並以既有對話進行受控 AX／選單／剪貼簿實測，沒有讀取訊息、rollout、認證資料或程序記憶體。以下明確區分程式碼證據與尚未完成的真機驗證；這不是「已找到 Hintlet 可使用的被動辨識 API」的宣告。

## 確定存在的精確映射

Codex renderer 知道目前 route 的 thread UUID 與 host ID，並且主程序確實保存了一份以視窗的 WebContents ID 為 key 的狀態。它不依賴對話名稱。

1. `webview/assets/app-initial-1ab6fbe93c4f.js` 的 `qji`，字元位置約 4,636,457：`M = r.value.routeKind === "local-thread" ? r.value.conversationId : null`；`N` 以同樣條件取得 `hostId`。
2. 同檔約 4,639,390，透過 `app-shell-shortcut-state-changed` 送出 `quickChatAppshotThreadTarget: M == null ? null : {conversationId:M, hostId:N??P}`。這在 React layout effect 內依 route 資料更新。
3. `.vite/build/main-CwxgTOle.js` 約 2,106,430 的訊息處理，呼叫 `windowManager.setAppShellShortcutState(e.id, {... quickChatAppshotThreadTarget:t.quickChatAppshotThreadTarget ...})`，`e` 是來源 WebContents。
4. 同檔約 3,724,049：setter 寫入 `appShellShortcutStates` 這個 `Map`；約 3,724,855 的 getter 以同一 ID 讀取。`forgetWebContents` 和視窗 closed callback 清除狀態。

因此，「App 自己也不知道目前是哪個 thread」不成立；目前的問題是如何從另一個 App 合法、穩定地讀到這份映射。這個特定欄位只覆蓋 `local-thread`，不能直接推廣到 ChatGPT cloud chat 或其他 route。

搜尋 setter/getter 的所有呼叫位置後，尚未找到把整個 Map 或這個欄位回傳給外部程序的公開方法。它的更新沒有直接寫入 global-state；不能把這個記憶體 Map 當成已存在的持久檔案。

## 可精確取得當前對話的內建命令

Codex 有「Copy deeplink」命令，預設快捷鍵為 **⌘⌥L**，能由目前對話的 route UUID 產生連結，無須查詢標題。

- `.vite/build/src-DCNiwad_.js` 約 1,347,823：command ID `copyDeeplink`，default keybinding `CmdOrCtrl+Alt+L`。使用者可改快捷鍵，因此正式整合不能永久假設預設鍵。
- `.vite/build/main-CwxgTOle.js` 約 3,401,500 的 `M()`：取得 `BrowserWindow.getFocusedWindow()`；沒有可用焦點視窗時才使用 `ensurePrimaryWindowVisible`。約 3,406,552 的 `Ce` 傳送 `{type:"copy-deeplink"}` 給該視窗；`Pe` 為隱藏但支援 accelerator 的 native menu item。
- `webview/assets/thread-overflow-menu-dbaf97ce6992.js` 約 10,427：目前 thread 元件訂閱 `copy-deeplink` 並呼叫其 `copyAppLink` action，使用元件的 `conversationId` 和 `hostId`。
- `webview/assets/app-initial-1ab6fbe93c4f.js` 約 5,452,000 的 `Vda`：以 `codex://threads/${conversationId}` 建立連結；remote host 或 thread access 資訊存在時使用 `Fda` 包裝。

另一個命令 `copyConversationPath` 的預設快捷鍵為 **⌘⌥⇧C**，會要求複製對話路徑。但 deep link 較直接，避免需要解析本機路徑。

這個介面後來已完成受控實測，結果見文末；全域快捷鍵也找到下述廣播問題，因此不採用它作為可靠 getter。它會寫入剪貼簿，並非被動讀取；在使用者同時複製內容、快速切換 route 或視窗時，需要競態與剪貼簿還原設計。即使一次取得 UUID 正確，也還不能假定之後畫面仍是同一個 thread；自動便利貼必須在導航時立即隱藏並重新確認。目前尚未證實可用於無干擾的持續追蹤。

## 本機 native pipe 不等於公開 route 查詢

主程序確實開設 JSON-RPC native pipe，但觀察到的 dynamic app tools pipe 並未提供 window-route read method：

- `.vite/build/main-CwxgTOle.js` 約 307,295 的 `moe` schema：接受 `taskProject/list`、`taskProject/assign`、`taskWorkspace/prepare`、browser access 相關要求，以及 `tools/list`、`tools/call`、`tools/cancel`。
- `tools/call` 明確要求 callerSource、callId、hostId、namespace、threadId、tool、turnId。caller 的 threadId 是工具執行上下文，不是「目前可見視窗」的觀測值。
- 同檔約 3,798,720，`hoe` 將要求轉入 `WindowContext.callDynamicAppTool` 等函式；沒有直接暴露 `getAppShellShortcutState`。
- pipe 為 frame-based JSON，最大 frame 8 MiB；macOS socket 會 chmod 0600。更重要的是 `jf()` 載入 `native/browser-use-peer-authorization.node`，在建立 socket 連線時對 peer 程序做原生授權。
- `.vite/build/build-flavor-CYXpoCFI.js` 的 `shouldIncludeBrowserUsePeerAuthorization` 對 macOS 的 Nightly、InternalAlpha、PublicBeta、Prod 都啟用這個授權；不能因同一使用者可讀 socket path，就認為 Hintlet 能直接連線。

本次沒有嘗試偽裝 peer、繞過授權、呼叫未授權工具、開啟 debug port、注入腳本或重啟 Codex。

## 證據定位與重現

所有字元位置是解包後 JavaScript 字串索引；minified 檔案多數只有一行，使用可搜尋的 symbol/字串定位比行號更可靠。這些屬於此安裝版本的內部實作，未宣稱官方支援的外部 API。

| 檔案 | SHA-256 |
|---|---|
| `.vite/build/main-CwxgTOle.js` | `87d52265eb13608a380fabcac47ecf13a39b981115c0960c18af563ea6d32d51` |
| `.vite/build/src-DCNiwad_.js` | `86fb2066bbc2f7428864b76b46ef570b09eb1e92e81e9d6f089f5b048a66df25` |
| `.vite/build/build-flavor-CYXpoCFI.js` | `23229dac961a82c52237acc32598ddb2c1cf370b24c64fc507b9c24bcf2c4d93` |
| `webview/assets/app-initial-1ab6fbe93c4f.js` | `f3d5fedc993d0ead2720c9877d8c72a82dc5fb2d935f13ad9426e6964fb6f105` |
| `webview/assets/thread-overflow-menu-dbaf97ce6992.js` | `43ca3b530f9994010fac4c6e867edc6f98f71562bbe34854f45cf39891cef887` |

下一個驗證重點：優先找可被動讀取的 OS scripting/window 介面；若沒有，對「Copy deeplink」做受控真機驗證，再評估能否在不破壞剪貼簿與焦點、不保留過期對話的條件下使用。必須測兩個視窗、同名對話、切換瞬間、新對話草稿與非對話頁；一次成功取得 UUID 不足以宣稱功能完成。

## 後續補充：快捷鍵的可靠性邊界

已受控實測 `CGEvent.postToPid` 送出 ⌘⌥L：目前對話與兩個同名但不同 UUID 的對話，分別成功取得預期的 `codex://threads/...`，約 105–116 ms；剪貼簿由探測程序只在記憶體中保存並還原。實測結果與限制整理如下。

程式碼另外揭露一個必須驗證的風險：native shortcut 不是傳回具 request ID 的 UUID 回覆，而是對 renderer 的廣播事件。

- `webview/assets/app-shared-8340f229c2b3.js`：`hre`（export `Pvn`，thread-overflow 中 import 為 `ue`）將 handler 註冊至 singleton `Vf`。`deliverMessage` 對同類訊息的所有已訂閱 handler 逐一呼叫，沒有內建 active pane 篩選。
- `thread-overflow-menu-dbaf97ce6992.js` 的 `copy-deeplink` handler 只判斷 `conversationId` 是否非空，沒有判斷 visibility 或 focus。
- `projects-index-page-8725b5a09d4a.js` 約 52,993，會為 project thread row render 同一個 overflow 元件。因此非對話頁上可能同時存在多個 handler。不能把「快捷鍵後收到合法 UUID」直接視為「目前對話是此 UUID」的證明。
- 當多個 hidden tab 或 split pane 還保留元件時，也需要實測它們的 lifecycle，不能假定只有一個 handler。

較直接的**特定元件 context menu**則會關閉上述廣播問題：`app-initial-1ab6fbe93c4f.js` 約 7,602,642，`copy-deeplink` menu item's `onSelect` 直接以該 row/header 的 `g`（UUID）和 `_`（host）呼叫 `copyAppLink`。如果 AX 能唯一定位目前對話 header 的 menu item，這個命令可精確取值；仍需考慮 menu 的焦點擾動與切換競態。

剪貼簿路徑已追到實際主程序：app-shared 約 6,694,462 的 `ONi`（export `TT`）對字串呼叫 `appServices.clipboard.writeText`；main 約 865,546 的 `spe.writeText(e)` 直接呼叫 Electron `clipboard.writeText(e)`，沒有指定另一個 pasteboard。沒有找到此命令改用私有 pasteboard 或僅回傳連結的選項。

快捷鍵覆寫檔是 `<CodexHome>/keybindings.json`。main shared `src-DCNiwad_.js` 約 1,397,052 的 `lK/dK/fK/pK` 會讀取陣列 `{command:string,key:string|null}`；`null` 可關閉預設快捷鍵。本機該檔存在，目前沒有 `copyDeeplink` entry。正式整合需要處理覆寫、停用與衝突，不能把預設鍵寫死後宣稱一律支援。

新增 native window 的來源：main `wZe` 的 `newWindow` menu action 呼叫 `createFreshWindow("/")`；沒有預設快捷鍵。thread context menu 的「Open in new window」以明確 `/local/<uuid>` route 送出 `open-in-new-window`，但受 feature gate `459748632` 控制；未找到穩定的 deep-link query 可強制另開視窗。

## 真機結果：目前對話的專屬選單可取得精確 ID

定位到目前視窗中的 `AXPopUpButton`，其控制項標籤為 `Chat actions`。以 AXPress 開啟後，其 `Copy` 子選單有 `Copy deeplink`。對這個具體 menu item 執行 AXPress，會呼叫該 header 的直接 action，不發送全域 `copy-deeplink` 廣播。這比單純模擬快捷鍵更精確，也不受使用者快捷鍵覆寫影響。

受控測試只用本機已存在的對話，不輸入訊息、不改名；同名測試的兩個 thread 由資料庫確認 title 相同，但識別結果以命令產生的 UUID 與預先指定 UUID 比較，沒有拿 title 做識別。

| 測試 | 實測結果 |
|---|---|
| 專屬選單：原對話 | UUID 符合預期；原型約 678 ms，交付探測工具約 786 ms |
| 專屬選單：同名對話 A | UUID 符合 A 的預期值；約 655 ms |
| 專屬選單：同名對話 B | UUID 符合 B 的預期值；約 673 ms |
| 剪貼簿 | 上述成功測試中，資料表示只保存在探測程序記憶體，測後還原；未記錄原內容 |
| 鎖定／Codex 不在前景 | 後續重跑時回傳 `Codex must be frontmost`，沒有執行選單或剪貼簿操作；檢查時前景程序為 `com.apple.loginwindow` |
| 多視窗 | 嘗試專屬選單 `Open in new window` 後仍僅觀測到一個 AX window，但 AX element reference 改變；不能據此宣稱已測過兩個同時存在的視窗。新顯示頁能複製預期 ID，約 2.9 s，仍不算跨視窗映射驗證 |
| 同視窗多面板／隱藏 tab、切換競態、草稿／設定／Projects | 尚未完成。快捷鍵在 Projects 有程式碼層級廣播風險，不能拿快捷鍵成功當成這些情況的驗證 |

多視窗嘗試後只對該次出現、與原 AX reference 不同的視窗送出關閉，再送 deep link 回到原對話；由於 AX reference 不足以證明是第二個 native window，後續多視窗測試應改以穩定 window-server number 記錄來源／目的視窗，不能重用這個判定方式。沒有關閉 App 或終止任何工作。

### 交付的重現工具

[`Tools/codex-conversation-link-probe.swift`](../../Tools/codex-conversation-link-probe.swift)：

```sh
swift Tools/codex-conversation-link-probe.swift --copy-deeplink --expect <known-local-thread-uuid>
```

這是**主動式研究探測工具，不是正式 identifier**。需明確傳 `--copy-deeplink`；僅在 Codex 在前景、焦點視窗只有一個可見 chat panel 與一個 `Chat actions` 時動作，控制項標籤目前只支援實測的英文介面。執行期間不要操作 App 或剪貼簿，僅用已知的本機對話。它開啟選單、從剪貼簿解析本機 `codex://threads/<uuid>`，最後只輸出 ID 的假名、耗時和是否符合預期。視窗或 panel token 改變時拒絕結果；此檢查是實驗性的拒絕條件，並非已證明涵蓋所有 route transition。

工具嘗試保留全部可讀的剪貼簿資料表示（8 MiB 上限）；不能完整備份時不執行。成功後只有 changeCount 未再變動才還原；不記錄原剪貼簿資料。**仍有不能忽略的限制：**

- `changeCount` 不是寫入者證明。若其他程序或使用者剛好同時複製另一個合法 Codex link，仍可能誤認來源並在還原時覆寫它。因此受控環境成功不等於並行安全，不能直接用於背景自動綁定。
- 若命令複製的是不支援的 remote／cloud link 或未知格式，工具無法判斷這次剪貼簿變化是否由命令造成，會留下該值並明確回報未還原，避免猜測後覆寫使用者的並行複製。故本次只測已知本機對話。
- 還原的是資料表示，無法恢復原 pasteboard owner、lazy provider、剪貼簿歷史管理器的觀察或原 changeCount。開選單也有焦點與可見介面擾動。
- 多面板、設定浮層或不熟悉的版本／locale 應拒絕，不能選第一個相似按鈕，更不能改用名稱配對。

原型曾在選單測試後送 Escape；交付工具改為只對仍存在的 AXMenu 送 AXCancel，避免 Escape 在選單已關閉時送進對話而打斷執行。

### AppleEvents 路徑實測

安裝包 Info.plist 確實設定 `NSAppleScriptEnabled = true` 並宣告 `scripting.sdef`，不是只有猜測 Chromium 會支援。以 `AEDeterminePermissionToAutomateTarget(..., false)` 查既有權限，回傳 0；沒有提出 Automation 權限要求。

但 `count windows` 回傳 0（同時 AX 可看到一個視窗），`URL of active tab of front window` 回傳 -1719。因此目前腳本字典的 browser window/tab 介面沒有涵蓋這個 Codex 對話視窗，不能用來取得其 thread。沒有執行 JavaScript。

## 目前可採用的結論

比報告 07 有明確進展：**已實測可透過指定對話 header 的原生選單取得真正 UUID，同名完全不影響。** 之前把「AXURL 不含 ID」當成沒有其他識別路徑的理由不夠完整。

然而，「每個 chat 視窗能無干擾、持續、並行安全地自動綁定」還沒有驗證完成。後續應把兩件事分開：

1. 精確取得單一 header 的 ID：已驗證的 menu action 可作為受控探索基礎；正式設計要解決剪貼簿寫入歸屬、焦點／route 競態及介面擾動，不能直接把本工具放進 Timer。
2. 被動取得視窗映射：main 已有精確 map，但目前沒有找到 Hintlet 可用的外部 read API。若要完全被動，最乾淨的介面是由 Codex 將 current thread ID 暴露在 AX、腳本介面或授權的本機查詢介面；本次未改動 Codex、未開 debug port、未讀程序記憶體。

本次不需要使用者同意「名稱唯一才綁定」，也沒有再推進該折衷。保留原需求的準確識別門檻，功能整合、AI 便利貼與最終 ADR／規格更新仍待上述驗證與正式 adapter 設計。
