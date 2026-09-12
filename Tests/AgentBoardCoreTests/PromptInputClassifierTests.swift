import XCTest
@testable import AgentBoardCore

final class PromptInputClassifierTests: XCTestCase {
    private func classify(_ text: String) -> PromptInputEffect {
        PromptInputClassifier.classify(Array(text.utf8)[...])
    }

    private func classify(_ bytes: [UInt8]) -> PromptInputEffect {
        PromptInputClassifier.classify(bytes[...])
    }

    func testPrintableAsciiDirtiesThePrompt() {
        XCTAssertEqual(classify("hello"), .dirties)
        XCTAssertEqual(classify(" "), .dirties)
        XCTAssertEqual(classify("~"), .dirties)
    }

    func testMultiByteUTF8DirtiesThePrompt() {
        XCTAssertEqual(classify("é"), .dirties)
        XCTAssertEqual(classify("日本語"), .dirties)
        XCTAssertEqual(classify("🙂"), .dirties)
    }

    func testCarriageReturnSubmits() {
        XCTAssertEqual(classify("\r"), .submits)
        XCTAssertEqual(classify("hello\r"), .submits)
    }

    func testLineFeedSubmits() {
        XCTAssertEqual(classify("\n"), .submits)
        XCTAssertEqual(classify("hello\n"), .submits)
    }

    func testTextTypedAfterASubmitLeavesThePromptDirty() {
        XCTAssertEqual(classify("hello\rmore"), .dirties)
    }

    func testControlCCancels() {
        XCTAssertEqual(classify([0x03]), .cancels)
        XCTAssertEqual(classify([0x68, 0x69, 0x03]), .cancels)
    }

    func testControlUCancels() {
        XCTAssertEqual(classify([0x15]), .cancels)
        XCTAssertEqual(classify([0x68, 0x69, 0x15]), .cancels)
    }

    func testLoneEscapeCancels() {
        XCTAssertEqual(classify([0x1b]), .cancels)
        XCTAssertEqual(classify([0x68, 0x69, 0x1b]), .cancels)
    }

    func testArrowKeysAreNeutral() {
        XCTAssertEqual(classify([0x1b, 0x5b, 0x41]), .neutral)
        XCTAssertEqual(classify([0x1b, 0x5b, 0x42]), .neutral)
        XCTAssertEqual(classify([0x1b, 0x5b, 0x43]), .neutral)
        XCTAssertEqual(classify([0x1b, 0x5b, 0x44]), .neutral)
        XCTAssertEqual(classify([0x1b, 0x4f, 0x41]), .neutral)
    }

    func testAnArrowKeyAfterTextDoesNotCleanThePrompt() {
        XCTAssertEqual(classify([0x68, 0x69, 0x1b, 0x5b, 0x44]), .dirties)
    }

    func testBackspaceIsNeutral() {
        XCTAssertEqual(classify([0x7f]), .neutral)
        XCTAssertEqual(classify([0x08]), .neutral)
    }

    func testKittyEncodedEnterIsNeutralRatherThanASubmit() {
        XCTAssertEqual(classify([0x1b] + Array("[13;2u".utf8)), .neutral)
    }

    func testAltEnterDirtiesBecauseItInsertsANewline() {
        XCTAssertEqual(classify([0x1b, 0x0d]), .dirties)
        XCTAssertEqual(classify([0x1b, 0x0a]), .dirties)
    }

    func testBracketedPasteContainingANewlineDirties() {
        let burst = Array("\u{1b}[200~first line\rsecond line\u{1b}[201~".utf8)
        XCTAssertEqual(classify(burst), .dirties)
    }

    func testBracketedPasteFollowedByASubmitSubmits() {
        let burst = Array("\u{1b}[200~pasted\u{1b}[201~\r".utf8)
        XCTAssertEqual(classify(burst), .submits)
    }

    func testUnterminatedBracketedPasteDirties() {
        let burst = Array("\u{1b}[200~pasted\r".utf8)
        XCTAssertEqual(classify(burst), .dirties)
    }

    func testRawPasteBurstEndingInTextDirties() {
        XCTAssertEqual(classify("line one\nline two"), .dirties)
    }

    func testEmptyInputIsNeutral() {
        XCTAssertEqual(classify([]), .neutral)
    }
}
