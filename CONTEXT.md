# Hintlet

macOS 上的便利貼工具：把筆記貼在使用者正在處理的工作內容上，切走時隱藏、回來時重現，幫助恢復工作記憶。

## Language

### 筆記

**便利貼（Note）**：
使用者手寫的一張卡片（5 種顏色，預設黃色），有自己的內容、位置、尺寸與收合狀態。一個工作內容可以有多張便利貼。
_Avoid_: Sticky, memo, card

**手寫便利貼（Manual Note）**：
內容完全由使用者撰寫的便利貼。
_Avoid_: Normal note, user note

**AI 便利貼（AI Note）**：
內容只由 AI 產生、使用者不能編輯的便利貼，以三行呈現某個對話「正在做什麼／停在哪裡／下一步」；每個對話最多一張。
_Avoid_: 脈絡（易與 App 名稱及工作內容混淆）, summary card

**浮動便利貼（Floating Note）**：
沒有綁定任何工作內容、始終顯示的便利貼。
_Avoid_: Pinned note, global note

**收合（Collapsed）**：
便利貼縮成小標記的狀態；屬於單張便利貼，不是工作內容的屬性。
_Avoid_: Minimized, hidden

**垃圾桶（Trash）**：
被刪除的便利貼暫存處，可在保留期內復原。
_Avoid_: Archive

### 綁定

**工作內容（Context）**：
使用者此刻注意力所在、可被識別的對象，例如某個 Claude 對話或某個 Codex thread。
_Avoid_: Target, page, window（視窗只是其中一種範圍）

**新對話草稿（Draft Conversation）**：
AI App 中「尚未送出、還沒有對話 ID」的新對話頁面；它不是工作內容，不能在上面貼便利貼。
_Avoid_: Empty chat, new tab

**範圍（Scope）**：
綁定所依附的層級，例如「App 視窗」、「資料夾／文件」（以路徑辨識，任何視窗打開它都算）、「網頁」（以正規化的網址辨識，任何分頁或視窗打開它都算）或「AI 對話」。範圍越細，便利貼出現得越精準。
_Avoid_: Level, granularity

**綁定（Binding）**：
便利貼與某個工作內容在某個範圍下的對應關係，包含用來辨識該內容的識別資訊。
_Avoid_: Attachment, link

**降級（Fallback）**：
無法辨識較細的範圍時，明確改用較粗的範圍綁定，並在介面上標示。
_Avoid_: Guess

**待找回（Unmatched）**：
綁定目前無法對應到任何現存工作內容的便利貼；保留不刪，可在列表中重新綁定。
_Avoid_: Orphan, lost, broken
