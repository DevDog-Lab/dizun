import Darwin
import Foundation

/// com.apple.quarantine propagation: everything extracted from a downloaded
/// archive must carry the attribute too, or Gatekeeper never sees the
/// contents. Failures are reported, never swallowed silently.
public enum Quarantine {
    private static let attributeName = "com.apple.quarantine"

    public static func attribute(of url: URL) -> Data? {
        let path = url.path
        let length = path.withCString { cPath -> Int in
            getxattr(cPath, attributeName, nil, 0, 0, 0)
        }
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = path.withCString { cPath -> Int in
            getxattr(cPath, attributeName, &buffer, buffer.count, 0, 0)
        }
        guard read == length else { return nil }
        return Data(buffer)
    }

    /// True when the attribute was set. False (reported by the caller) means
    /// part of what was extracted is invisible to Gatekeeper.
    public static func apply(_ value: Data, to url: URL) -> Bool {
        url.path.withCString { cPath -> Bool in
            value.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                guard let base = raw.baseAddress else { return false }
                return setxattr(cPath, attributeName, base, raw.count, 0, 0) == 0
            }
        }
    }
}
