import Foundation

/// Bookkeeping for a load that runs off the main thread and may finish
/// after something newer has replaced it.
///
/// A window that reloads on every filter change, every external mutation
/// and every scope switch can have several loads in flight at once, and
/// they do not necessarily finish in the order they started. Applying a
/// result that a later load has already superseded would put stale rows on
/// screen, so each load carries the number it was issued and only the
/// newest number is applied.
public struct ClipboardLoadGenerations: Sendable, Equatable {
    /// Number of loads started.
    public private(set) var issued = 0
    /// Highest generation whose completion has been seen, in progress order
    /// rather than arrival order — a completion never lowers it.
    public private(set) var completed = 0

    public init() {}

    /// Starts a load and returns the generation its completion must carry.
    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// Records a completion and reports whether its result should be
    /// applied. False means a newer load has already started and this
    /// result is stale.
    public mutating func accept(_ generation: Int) -> Bool {
        completed = max(completed, generation)
        return generation == issued
    }

    /// True while `generation` has not completed — what a delayed
    /// "still loading" hint checks before it shows itself.
    public func isOutstanding(_ generation: Int) -> Bool {
        completed < generation
    }

    /// True while any load is in flight.
    public var isLoading: Bool {
        completed < issued
    }
}
