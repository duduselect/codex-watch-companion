import XCTest
@testable import CodexWatchCompanion

final class LocalizationTests: XCTestCase {
    func testActiveCatalogIsSimplifiedChineseOrEnglishFallback() {
        if Bundle.main.preferredLocalizations.first == "zh-Hans" {
            XCTAssertEqual(L10n.text("Sending"), "正在发送")
            XCTAssertEqual(L10n.bridgeText("已排队"), "已排队")
        } else {
            XCTAssertEqual(L10n.text("Sending"), "Sending")
            XCTAssertEqual(L10n.bridgeText("已排队"), "Queued")
        }
    }
}
