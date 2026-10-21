# 以「唯一的標題」辨識 Codex 對話

Codex App（`com.openai.codex`，Electron）的網址固定是 `app://-/index.html`，AX 樹與本機狀態都沒有記錄畫面上開著哪個 thread（2026-10-21 實測：`AXURL`、`~/.codex/state_5.sqlite` 的 `threads` 表、App 的本機儲存都沒有）。唯一的訊號是網頁區域的標題，也就是 thread 名稱。ADR-0001 因此原本不支援 Codex 對話。

使用者決定放寬這條規則，但只限 Codex：

- 網頁區域標題在 `~/.codex/session_index.jsonl`（每個 thread 改名時會追加一行，以最後一行為準）裡**只對到一個 thread**，才綁到那個對話，而且便利貼存的是 **thread ID**，不是標題。之後改名時，只要新名字也是唯一的，就還對得到。
- 標題對到好幾個 thread（例如好幾個都叫 "Guardian review"）就分不出來，退回視窗範圍，標籤會註明。
- 沒有 thread 叫這個名字（新對話、設定頁）就是一般視窗。

## Considered Options

- **維持只綁視窗**：最安全，但 Codex 對話無法有自己的便利貼和 AI 便利貼。
- **重名時選最近更新的那個**：大多數時候是對的，但會錯誤顯示，違反「寧可晚一點出現，也不能錯誤出現」。
- **從「Chat actions → 拷貝連結」取得 thread UUID**：唯一精確的方法（[報告 07–09](../spikes/0009-codex-identification-performance.md)，約 215 ms），但每次都要打開選單並借用系統剪貼簿，會干擾使用者，不能在每次切換或背景執行。
- **讀 `state_5.sqlite`**：同樣沒有「目前開著哪個」的欄位，而且資料庫正在被 Codex 寫入，讀取需要更多權限。

## Consequences

- 錯配只剩一種情況：你開著某個 thread 時，另一個 thread 剛好被改成同一個名字。這時兩者都不再唯一，便利貼會退回視窗，不會出現在錯的對話上。
- 對 Codex 設定 `AXManualAccessibility`（打字讓路本來就需要）。設定後大約 1 秒，網頁區域才會出現在 AX 樹裡；在那之前，便利貼會先停在視窗上。
- 切換 thread 沒有系統通知。Codex 內焦點一移動就讀一次標題；焦點沒動的切換（例如點側欄），靠 Codex 在前景時每 0.25 秒讀一次標題補上。
- AI 便利貼從 `~/.codex/sessions/**/rollout-*-<thread>[_<branch>].jsonl` 讀取對話。改過前面的訊息時，Codex 會另開一個分支檔，接續原本的編號；讀取時用第一個檔到分支起點，再接最新的分支。只保留使用者和 Codex 說的話。
- Codex 刪除或封存 thread 的情況還不偵測，便利貼不會自動進垃圾桶。
