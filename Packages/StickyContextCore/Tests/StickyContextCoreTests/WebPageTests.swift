import Foundation
import Testing
import StickyContextCore

@Suite("認出瀏覽器顯示的網頁")
struct RecognisingWebPages {
    @Test("# 之後的部分去掉：同一頁的不同段落是同一個網頁")
    func dropsTheFragment() {
        #expect(WebPages.normalizedAddress("https://example.com/guide#install") == "https://example.com/guide")
    }

    @Test("? 參數保留：YouTube 的 ?v= 是不同影片")
    func keepsTheQuery() {
        #expect(WebPages.normalizedAddress("https://www.youtube.com/watch?v=abc123")
            == "https://www.youtube.com/watch?v=abc123")
        #expect(WebPages.normalizedAddress("https://www.youtube.com/watch?v=abc123")
            != WebPages.normalizedAddress("https://www.youtube.com/watch?v=xyz789"))
    }

    @Test("主機名稱不分大小寫，路徑分")
    func hostIsCaseInsensitive() {
        #expect(WebPages.normalizedAddress("HTTPS://Example.COM/Docs") == "https://example.com/Docs")
    }

    @Test("結尾的 / 視為相同")
    func trailingSlashIsTheSame() {
        #expect(WebPages.normalizedAddress("https://example.com/docs/") == "https://example.com/docs")
        #expect(WebPages.normalizedAddress("https://example.com/") == "https://example.com")
        #expect(WebPages.normalizedAddress("https://example.com") == "https://example.com")
        #expect(WebPages.normalizedAddress("https://example.com/?q=1") == "https://example.com?q=1")
    }

    @Test("看不懂的網址沒有正規化結果")
    func unparsable() {
        #expect(WebPages.normalizedAddress("not a url") == nil)
    }

    @Test("一般網頁以正規化的網址辨識，帶網頁標題")
    func ordinaryPage() {
        #expect(WebPages.page(address: "https://Example.com/guide/#top", title: "指南")
            == .page(address: "https://example.com/guide", title: "指南"))
    }

    @Test("新分頁、起始頁：還沒有網頁可以貼")
    func newTabs() {
        for address in ["", "about:blank", "about:newtab", "favorites://", "topsites://", "chrome://newtab/",
                        "chrome://new-tab-page/", "chrome-search://local-ntp/local-ntp.html"] {
            #expect(WebPages.page(address: address, title: "") == .newTab, "\(address)")
        }
    }

    @Test("瀏覽器自己的頁面（設定、擴充功能）和讀不到網址時降級到視窗")
    func internalPages() {
        for address in ["chrome://settings/", "chrome://extensions/", "about:preferences", "safari-resource:/x", nil] {
            #expect(WebPages.page(address: address, title: "設定") == .unrecognized, "\(address ?? "nil")")
        }
    }

    @Test("本機檔案不是網頁：交給資料夾與文件範圍")
    func localFiles() {
        #expect(WebPages.page(address: "file:///Users/me/report.html", title: "報告") == nil)
    }

    @Test("無痕或私密瀏覽視窗不讀網址")
    func privateWindows() {
        #expect(WebPages.page(address: "https://example.com", title: "範例", isPrivate: true) == .privateWindow)
    }

    @Test("Safari：IsSecure 只代表 HTTPS，不是私密瀏覽（實測：一般 HTTPS 網頁是 true、私密起始頁是 false）")
    func safariIsSecureIsHTTPS() {
        #expect(!WebPages.isPrivateWindow(title: "範例", addressFieldDescriptions: ["smart search field"], buttonLabels: []))
    }

    @Test("Safari 私密視窗：網址列寫著「in a private window」（實測）")
    func safariPrivateWindow() {
        #expect(WebPages.isPrivateWindow(title: "範例", addressFieldDescriptions: ["smart search field in a private window"], buttonLabels: []))
        #expect(WebPages.isPrivateWindow(title: "範例", addressFieldDescriptions: ["私密視窗中的智慧型搜尋欄位"], buttonLabels: []))
    }

    @Test("Chrome 無痕視窗：標題結尾或工具列按鈕寫著「Incognito」（實測）")
    func chromeIncognitoWindow() {
        #expect(WebPages.isPrivateWindow(title: "New Incognito Tab - Google Chrome (Incognito)", addressFieldDescriptions: [], buttonLabels: []))
        #expect(WebPages.isPrivateWindow(title: "範例", addressFieldDescriptions: [], buttonLabels: ["返回", "Incognito"]))
        #expect(WebPages.isPrivateWindow(title: "範例", addressFieldDescriptions: [], buttonLabels: ["無痕模式"]))
        #expect(!WebPages.isPrivateWindow(title: "Incognito mode explained", addressFieldDescriptions: ["Address and search bar"],
                                          buttonLabels: ["返回", "Incognito mode"]))
    }
}
