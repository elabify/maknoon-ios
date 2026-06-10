// Shared helper for distinguishing a "real" network failure from a fetch
// that was simply superseded. Pull-to-refresh racing a `.task(id:)`, a
// wallet/network switch restarting an in-flight request, or two refreshes
// overlapping all surface as cancellation (Swift `CancellationError` or
// NSURLErrorCancelled / -999). Those are not failures the user should see:
// the newer request is already running, so callers bail quietly and keep
// whatever data they had. Used by the Ethereum, Lightning, and Bitcoin
// wallet views.

import Foundation

/// True when `error` is task/request cancellation (a superseded fetch),
/// not a genuine failure.
func isSupersededFetch(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
}
