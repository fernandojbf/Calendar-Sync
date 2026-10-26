import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// An exclusive lock on a file, held for as long as this object lives. The app takes one at
/// launch so only one copy runs: two copies would both sync and could copy events twice. A
/// lock rather than a look at the running apps, because two copies starting together at login
/// can each miss the other. The kernel drops the lock when the process ends, crash or not, so
/// nothing stale is left behind.
public final class InstanceLock {
    public struct Failure: Error, Equatable {
        public var path: String
        public var errno: Int32
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Takes the lock on `url`, creating the file and its folder if needed. nil when another
    /// process, or another `InstanceLock` in this one, already holds it. Throws when the file
    /// can't be opened or locked for any other reason.
    public static func acquire(at url: URL) throws -> InstanceLock? {
        let path = url.path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure(path: path, errno: errno) }

        // Each open() is its own open file description, so this also conflicts with a lock
        // held through another descriptor in this process.
        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX | LOCK_NB)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw Failure(path: path, errno: error)
        }
        return InstanceLock(descriptor: descriptor)
    }
}
