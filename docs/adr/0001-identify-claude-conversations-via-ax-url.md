# 以輔助使用網址（AXURL）辨識 Claude 對話

要把便利貼綁到 Claude 桌面 App 的單一對話，我們讀取 Claude 網頁區域的 AXURL（`/chat/<uuid>`、`/cowork/local_<uuid>`、`/epitaxy/local_<uuid>`），取其中的對話 ID 作為識別；必要時才對 Claude 開啟 `AXManualAccessibility`，並先向使用者說明。理由：這是唯一同時具備「每個對話唯一、重啟後不變、改名不受影響、使用公開 API、不需額外權限」的訊號。

## Considered Options

- **視窗標題**：Claude 主視窗標題固定為「Claude」（已在本機實測），無法區分對話；即使未來顯示頁面標題，也會撞名且改名即失效。
- **螢幕截圖＋OCR**：需要螢幕錄製權限、不準確，且違反「預設不持續錄製螢幕」。
- **監看 Claude 本機檔案**：只有 Code 分頁切換時會寫入 `lastFocusedAt`；Chat 與 Cowork 沒有可監看的訊號。可作為 Code 的輔助訊號，不能作為主要機制。
- **侵入 Claude（除錯埠、注入程式碼）**：隨 Claude 更新而壞，且有安全疑慮。

## Consequences

- 依賴 Claude 的內部路由格式；此邏輯隔離在 Claude 專屬的 ContextProvider adapter 中，格式不符時明確降級為視窗綁定，絕不顯示可能錯誤的便利貼。
- AXURL 變化沒有可靠的系統通知，需在焦點／版面通知觸發後以低頻率讀取網址。
- 開啟 `AXManualAccessibility` 會讓 Claude 多用一些 CPU 與記憶體，狀態維持到 Claude 重開。
- 第一版不支援網頁與 Codex：Codex 的路由只存在記憶體中，AXURL 不含 thread ID，唯一可行訊號是畫面標題，不符合可靠識別的要求。兩者在支援矩陣中標示為未支援，其視窗仍可用一般視窗綁定。
