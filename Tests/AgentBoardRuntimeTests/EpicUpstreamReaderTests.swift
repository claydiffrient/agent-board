import AgentBoardCore
import AgentBoardRuntime
import XCTest

final class EpicUpstreamReaderTests: XCTestCase {
    private func view(state: String, fork: Bool = false) -> String {
        #"{"headRefName":"feature/widgets","isCrossRepository":\#(fork),"number":42,"#
            + #""state":"\#(state)","url":"https://github.com/example-org/app/pull/42"}"#
    }

    func testOnlyAnOpenSameRepositoryPullRequestBecomesAnUpstream() throws {
        XCTAssertEqual(
            try EpicUpstreamReader.upstream(from: view(state: "OPEN"), number: 42),
            EpicUpstream(
                headRef: "feature/widgets",
                pullRequest: PullRequestReference(url: "https://github.com/example-org/app/pull/42", number: 42)
            )
        )
        for (json, reason) in [
            (view(state: "MERGED"), "is merged, not open"),
            (view(state: "CLOSED"), "is closed, not open"),
            (view(state: "OPEN", fork: true), "comes from a fork"),
        ] {
            XCTAssertThrowsError(try EpicUpstreamReader.upstream(from: json, number: 42)) {
                XCTAssertTrue(String(describing: $0).contains(reason), "\(reason): \($0)")
            }
        }
    }
}
