import SwiftUI

/// The app menu's on-demand disk cleanup (SPEC §14.4). It runs whatever the free space.
struct CleanUpNowMenuItem: View {
    static let title = "Clean up now"

    let supervisor: any WorkerSupervising

    var body: some View {
        Button(Self.title) { _Concurrency.Task { await supervisor.cleanUpDiskNow() } }
    }
}
