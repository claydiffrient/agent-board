import XCTest
@testable import AgentBoardCore

final class ReleaseNotesBlocksTests: XCTestCase {
    func testAParagraphWrappedOverTwoLinesIsOneBlock() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("First release, written\nover two lines."),
            [.paragraph("First release, written over two lines.")]
        )
    }

    func testABlankLineSeparatesParagraphs() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("One.\n\nTwo."),
            [.paragraph("One."), .paragraph("Two.")]
        )
    }

    /// The shape `RELEASES.md` is written in: a wrapped bullet whose continuation lines are indented.
    func testAWrappedBulletStaysOneBullet() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("""
            - **Task Board.** Projects, epics and tasks in columns, with worker sessions
              started as `claude --bg`.
            - **Status.** Live session state.
            """),
            [
                .bullet(indent: 0, text: "**Task Board.** Projects, epics and tasks in columns, with worker sessions started as `claude --bg`."),
                .bullet(indent: 0, text: "**Status.** Live session state."),
            ]
        )
    }

    func testNestedBulletsCarryTheirDepth() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("- Top\n  - Nested\n    * Deeper"),
            [.bullet(indent: 0, text: "Top"), .bullet(indent: 1, text: "Nested"), .bullet(indent: 2, text: "Deeper")]
        )
    }

    func testHeadingsKeepTheirLevelAndDropTheHashes() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("### Fixed\n\nA thing."),
            [.heading(level: 3, text: "Fixed"), .paragraph("A thing.")]
        )
    }

    /// `#hashtag` and `#!/bin/sh` are not headings: the space after the hashes is what makes one.
    func testAHashWithNoSpaceIsNotAHeading() {
        XCTAssertEqual(ReleaseNotesMarkdown.blocks("#hashtag"), [.paragraph("#hashtag")])
    }

    func testAFencedBlockKeepsItsLinesAndItsMarkers() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("Run:\n\n```\nswift build\n# not a heading\n```\n\nDone."),
            [.paragraph("Run:"), .code("swift build\n# not a heading"), .paragraph("Done.")]
        )
    }

    func testAnUnclosedFenceStillYieldsItsContent() {
        XCTAssertEqual(ReleaseNotesMarkdown.blocks("```\nswift build"), [.code("swift build")])
    }

    func testAnEmptyBodyHasNoBlocks() {
        XCTAssertEqual(ReleaseNotesMarkdown.blocks("\n  \n"), [])
    }

    /// Inline markup is left alone here — `AttributedString(markdown:)` applies it at render time,
    /// and it is the one part of Markdown that does survive that call.
    func testInlineMarkupIsLeftForTheRenderer() {
        XCTAssertEqual(
            ReleaseNotesMarkdown.blocks("A **bold** word and `code`."),
            [.paragraph("A **bold** word and `code`.")]
        )
    }
}
