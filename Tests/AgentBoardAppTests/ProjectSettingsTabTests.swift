import XCTest
@testable import AgentBoard

/// Pins that no project setting can fall out of the tabbed sheet. The chain is: the sheet's only
/// `Section` is the one built from a `ProjectSettingsSection` (source scan), `content(for:)` is an
/// exhaustive switch over that enum (compiler), and every case sits in exactly one tab (here).
final class ProjectSettingsTabTests: XCTestCase {
    func testEverySectionAppearsInExactlyOneTab() {
        for section in ProjectSettingsSection.allCases {
            let placements = ProjectSettingsTab.allCases.flatMap { tab in
                tab.sections.filter { $0 == section }.map { _ in tab }
            }
            XCTAssertEqual(
                placements.count, 1,
                "\(section.title) is in \(placements.map(\.title)); it must be in exactly one tab"
            )
        }
    }

    func testEveryTabHoldsASection() {
        for tab in ProjectSettingsTab.allCases {
            XCTAssertFalse(tab.sections.isEmpty, "\(tab.title) is an empty tab")
        }
    }

    func testTheSheetBuildsNoSectionOutsideTheEnum() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentBoard/Views/ProjectSettingsSheet.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let sections = source
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"\bSection\s*[({]"#, options: .regularExpression) != nil }
        XCTAssertEqual(sections, ["Section(section.title) { content(for: section) }"])
    }
}
