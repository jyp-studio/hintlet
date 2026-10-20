# 驗證報告 06：終端機中的 Claude Code CLI 對話

日期：2026-10-18　Claude Code CLI 2.1.220（Homebrew）　macOS 27

探測腳本放在 session 的 scratchpad，沒有進 repo：用 Python `pty.fork()` 開一個假終端機，在裡面跑 `claude`，再用 `ps`／`sysctl` 和 `~/.claude/sessions/` 對照。過程中沒有對 Terminal 或 iTerm 送 Apple Events，也沒有模擬點擊或按鍵。

## 對應鏈

前景分頁 →（Apple Events）tty →（`sysctl KERN_PROC_TTY`）前景程序群組裡的 `claude` →（`~/.claude/sessions/<pid>.json`）session ID

## 已驗證

- **session 檔**：互動模式的 Claude Code 啟動後立刻寫 `~/.claude/sessions/<pid>.json`，裡面有 `sessionId`、`cwd`、`startedAt`（毫秒）、`procStart`（UTC 字串）、`entrypoint`、`kind`、`name`、`status`。
  - 在終端機啟動的 `entrypoint` 是 `"cli"`；Claude App 自己的 Code session 是 `"claude-desktop"`，而且沒有 tty。
  - 還沒送出任何訊息時檔案就在了，`sessionId` 已經定下來（和 Claude App 的新對話草稿不同）。
  - 同一資料夾還有 `<pid>.<hash>.key`，Hintlet 不讀。
- **tty → 程序**：`sysctl(KERN_PROC_TTY)` 用 tty 裝置號列出該 tty 上的程序，每筆有 `e_pgid`、`e_tpgid`（tty 的前景程序群組）、啟動時間與指令名稱。實測跟 `ps -t` 一致：
  - 直接執行：`claude` 自己是群組長，`pgid == tpgid`。
  - 從 zsh 啟動：zsh 的群組退到背景，`claude` 的群組在前景（`ps` 的 `S+`）。
  - 程序啟動時間比 session 檔的 `startedAt` 早約 0.4–0.9 秒。
- **同分頁多次啟動**：`/exit` 或 SIGTERM 結束時，Claude Code 自己刪掉 session 檔。同一個 shell 再啟動一次，會拿到新的 PID 和新的 session ID。
- **異常結束**：SIGKILL 之後 session 檔會留下來，PID 之後可能被別的程序重用。所以認 session 檔時要求：程序還在、在前景群組、程序啟動時間不晚於檔案的 `startedAt`（容許 2 秒誤差）。
- **resume**：`claude --resume <id>` 的 session 檔 `sessionId` 就是 `<id>`，所以重開同一個 session 時便利貼會回來，不管在哪個分頁、哪個視窗。`--fork-session` 會換新 ID（視為另一個對話）。
- **`/clear`**：同一個程序的 `sessionId` 會當場換成新的，檔案原地更新。便利貼跟著原本的 session 收起；之後 resume 原本那個 session，便利貼才會回來。
- **在 Claude Code 裡執行時**：從另一個 Claude Code 啟動的 `claude`（環境變數帶 `CLAUDE_CODE_CHILD_SESSION`）不寫 session 檔，也不存對話記錄。探測時要清掉 `CLAUDE*` 環境變數，才會跟一般終端機一樣。

## 待手動驗證（需要 Automation 權限，這次沒有請求）

前景分頁的 tty 只能用 Apple Events 取得。Terminal 和 iTerm 的輔助使用樹裡沒有 tty。視窗的 `AXDocument`（目前資料夾）不能拿來代替：同一個資料夾開兩個分頁、只有一個在跑 Claude Code 時，會認錯。

| App | 取得方式 | 四字碼 |
|---|---|---|
| Terminal | `tty of selected tab of window 1`，並比對 `name of window 1` 與 AX 視窗標題 | `cwin` 索引 1 → `tcnt` → `ttty`；`pnam` |
| iTerm | `tty of current session of current window`，並比對 `name of current window` | `Crwn` → `Wcsn` → `Stty`；`pnam` |

要手動確認的項目：

1. 第一次在跑著 Claude Code 的 Terminal 分頁前景時，系統詢問「Hintlet 想要控制 Terminal」，說明文字提到終端機分頁。如果沒有任何 Claude Code CLI 在跑，就不會詢問。
2. 允許後按 ⌘⌥N，便利貼標籤是「Claude 對話：<session 名稱>」。
3. 切到同視窗的另一個分頁（shell 或另一個 Claude Code），約 1 秒內便利貼收起或換成那個 session 的便利貼。兩個分頁標題相同也要能切換。
4. `/exit` 後約 1 秒內收起；`claude --resume <id>` 後回來。
5. Terminal 的 `name of window 1` 要和 AX 標題逐字相同（含「— 80×24」等尺寸字樣）。不同的話永遠問不到 tty，會一直降級到資料夾或視窗範圍。這種失敗是安全的，但功能等於沒有。
6. iTerm 重複 1–5。
7. 拒絕權限：便利貼綁在資料夾或視窗，不再詢問。

## 降級

以下情況一律不綁到 session，依序改綁資料夾（終端機有回報目前資料夾時）或視窗，不猜測：

- 沒有權限，或終端機沒有回答。
- 前景不是 Claude Code（shell、vim、Ctrl-Z 放到背景）。
- 前景有兩個 Claude Code。
- session 檔不符合上面的條件。
- 其他終端機 App（Ghostty、WezTerm、VS Code 內建終端機等）。

## 已知限制

- 在 Claude Code 啟動、還沒送出訊息時就可以貼。之後如果沒有送出就離開，這個 session 不會存檔，也無法 resume，便利貼會一直在「待找回」，要手動重新綁定或刪除。
- session 名稱是 Claude Code 自動取的（例如 `Note-24`），`/rename` 之後才是使用者取的名稱。
- `name` 欄位與 session 檔格式不是公開介面。Claude Code 改版後如果讀不到，會降級，不會綁錯。
- 啟動或結束 Claude Code 不會觸發任何輔助使用通知，所以終端機在前景時每秒檢查一次：讀 session 資料夾，必要時讀一次 tty 上的程序。

## 支援矩陣（給 ticket 13）

| 對象 | 狀態 | 備註 |
|---|---|---|
| Terminal 中的 Claude Code CLI | 實驗 | 對應鏈已實測；Apple Events 取 tty 待手動驗證 |
| iTerm 中的 Claude Code CLI | 實驗 | 同上 |
| 其他終端機中的 Claude Code CLI | 未支援 | 視窗或資料夾範圍 |
