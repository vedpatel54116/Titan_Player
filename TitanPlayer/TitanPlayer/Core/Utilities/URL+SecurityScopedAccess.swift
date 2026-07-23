import Foundation

extension URL {
    /// Performs `work` with the security-scoped resource accessible for the
    /// entire (possibly asynchronous) duration of the closure.
    ///
    /// Access is started *before* `work` runs and stopped in a `defer` block
    /// **only if** `startAccessingSecurityScopedResource()` returned `true`.
    /// This guarantees the access extension is released even when `work`
    /// throws partway through — preventing the per-open kernel resource leak
    /// that unbalanced `start`/`stop` pairs cause.
    ///
    /// URLs that are not security-scoped (e.g. files dragged from the Finder
    /// without a sandbox extension, or URLs already granted transient access
    /// by an open panel) simply proceed: `startAccessingSecurityScopedResource()`
    /// returns `false`, so `stop` is never called and `work` runs normally.
    @discardableResult
    func withSecurityScopedAccess<T>(_ work: (URL) async throws -> T) async throws -> T {
        let accessed = startAccessingSecurityScopedResource()
        defer {
            if accessed {
                stopAccessingSecurityScopedResource()
            }
        }
        return try await work(self)
    }
}
