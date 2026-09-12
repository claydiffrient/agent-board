import Foundation
import GRDB
import Observation

/// Publishes the latest value of a GRDB `ValueObservation`. Drive it from `.task(id:)`
/// so the observation restarts when its inputs change and stops when the view disappears.
@Observable
final class Observed<T> {
    var value: T
    var error: Error?

    init(_ initial: T) {
        value = initial
    }

    @MainActor
    func run<R: ValueReducer>(_ observation: ValueObservation<R>, in reader: any DatabaseReader) async
    where R.Value == T {
        do {
            for try await next in observation.values(in: reader) {
                value = next
            }
        } catch is CancellationError {
        } catch {
            self.error = error
            NSLog("Observed<%@> failed: %@", String(describing: T.self), String(describing: error))
        }
    }
}
