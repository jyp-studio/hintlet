# 驗證報告 04：Chat 完整內容與 claude:// 前往

日期：2026-10-14　Claude 桌面 App 2.37337.1

探測工具：[`Tools/claude-ax-probe.swift`](../../Tools/claude-ax-probe.swift) `messages`（只計數，不輸出內容）

## 結論

- **「前往」：納入。** `claude://claude.ai/<路徑>` 能直接打開三種對話：
  - Chat：`claude://claude.ai/chat/<uuid>`
  - Cowork：`claude://claude.ai/cowork/local_<uuid>`
  - Code：`claude://claude.ai/epitaxy/local_<uuid>`

  實測打開後的網址和標題都正確。若對話已刪除，Claude 會導到 `/new`。「前往」之後可以讀一次網址：如果落在新對話草稿，就把這張便利貼標成「待找回」。
- **Chat 內容：部分。** Chat 會隨捲動卸載可視範圍上方的訊息。使用者通常停在對話底部，這時只讀得到最後幾則（見下方「延遲載入」）。AI 便利貼要標示「已載入 N 則」。不要為了讀完整內容去捲動使用者的對話。

## 讀得到什麼

在三個 Chat 對話上，各自的輔助使用樹中可以分辨出：

- **Claude 回覆**：class 含 `group/message-row` 的群組，內有隱藏標題「Claude responded」。
- **使用者訊息**：class 含 `bg-user-message` 的泡泡，前面有隱藏標題「You said: …」。

依序排列後分別是 `A U A U A`、`A U A`、`A U A`。

- **能分辨誰說的**：用上述 class，或用隱藏標題的前綴。標題文字是無障礙用的英文字串，比 Tailwind class 穩定，建議以標題為主要依據、class 為備用。
- **「已載入 N 則」**：N 是樹中「You said」與「Claude responded」標題的數量。在第一個對話上，標題數（You said 2、Claude responded 3）和 class 計數（使用者 2、回覆 3）一致。

## 延遲載入（以測試對話確認）

經使用者同意，建了一個測試 Chat「這是 Hintlet 的測試對話…」，在裡面送了 4 則訊息，其中 3 則要求 Claude 列出 200 行數字，讓對話高度遠超過一個螢幕。

| 時機 | 樹中的訊息（U＝使用者，A＝Claude） |
|---|---|
| 剛送出第一則 | `U A`，完整 |
| 離開後再從歷史打開 | `U A`，完整 |
| 第 3 輪後，停在底部 | `U A U A U A`，完整 |
| 第 4 輪後，停在底部 | `A A U A`，最早的 5 則已從樹中消失 |
| 以滾輪捲到頂端 | `U A U A U A A U A`，9 則全部出現 |
| 再捲回底部 | `A A U A` |

- **會延遲載入**：可視範圍上方較遠的訊息會從輔助使用樹中移除，捲回去才重新出現。可視範圍外但還沒卸載的訊息，尺寸回報成 1px 高，文字完整。
- **先前三個舊對話缺第一則使用者訊息，原因就是延遲載入**：它們打開時停在底部，最上面的訊息已被卸載。這不是讀取方式的問題。
- **「已載入 N 則」的 N**：讀取當下樹中「You said」與「Claude responded」標題的總數。在多數情況下，N 等於「最後 N 則」。

## 不確定

- 更長的對話（上百則）在捲到頂端時，下方的訊息會不會也被卸載，還沒測。這不影響結論，因為我們不會替使用者捲動。
- **class 名稱穩定性**：`group/message-row`、`bg-user-message` 都是 claude.ai 前端的 Tailwind class，隨時可能改名。讀取邏輯要在找不到時明確回報「讀不到」，不能猜。
