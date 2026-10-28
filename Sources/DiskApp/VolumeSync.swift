import Foundation

public enum VolumeSync {
    /// Seconds a finished unmount waits before its drive counts as still mounted: the
    /// system may not have taken the volume away yet.
    public static let refusedUnmountGrace: TimeInterval = 5

    /// Drives whose controller is spent but whose volume is still mounted: the unmount
    /// was refused (for example "disk in use" after a Finder eject), so no didUnmount
    /// will come. Only unmounts that finished at least `grace` ago count, and never a
    /// drive the app itself is ejecting (that path replaces its own controller).
    public static func spentControllersToReplace(
        mounted: Set<String>, unmountFinished: [String: Date], ejecting: Set<String>,
        now: Date, grace: TimeInterval = refusedUnmountGrace
    ) -> Set<String> {
        Set(unmountFinished.compactMap { uuid, finished in
            mounted.contains(uuid) && !ejecting.contains(uuid) && now.timeIntervalSince(finished) >= grace ? uuid : nil
        })
    }
}
