import XCTest
@testable import CodexWatchCompanion

final class AudioLevelMeterTests: XCTestCase {
    func testReplySpeechKeepsChineseAndLinkLabelWithoutReadingCodeOrURL() {
        XCTAssertEqual(ReplySpeechText.plain("# 你好\n**完成**，请看[说明](https://example.com)。\n```swift\nprint(1)\n```"), "你好\n完成，请看说明。\n代码片段请查看屏幕。")
    }

    func testReplySpeechEmptyInputIsEmpty() {
        XCTAssertEqual(ReplySpeechText.plain("  \n "), "")
    }
    func testSilenceStaysNearWaveformFloor() {
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0, peak: 0), AudioLevelMeter.floor, accuracy: 0.001)
    }

    func testQuietSpeechMovesWaveformVisiblyAboveFloor() {
        let level = AudioLevelMeter.normalizedLevel(rms: 0.001, peak: 0.004)

        XCTAssertGreaterThan(level, 0.3)
    }

    func testNormalSpeechDrivesLargeWaveformMotion() {
        let level = AudioLevelMeter.normalizedLevel(rms: 0.005, peak: 0.025)

        XCTAssertGreaterThan(level, 0.55)
    }

    func testLoudInputClampsToMaximum() {
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0.25, peak: 0.9), 1, accuracy: 0.001)
    }
}
