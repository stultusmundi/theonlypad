import Darwin

public enum SearchParentLifetime {
  /// Call on one dedicated helper thread before admitting work. The descriptor
  /// must be the blocking read end of the parent's lifetime pipe, never a request
  /// stream. This deliberately terminates the entire helper without waiting for
  /// the main thread, engine work, Swift destructors, or Foundation exit handlers.
  public static func run(controlFD: Int32) -> Never {
    Darwin._exit(
      exitStatus(controlFD: controlFD) { fd in
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        return (count, count < 0 ? errno : 0)
      })
  }

  /// The syscall boundary is injected only internally; production always uses
  /// the blocking Darwin read above and immediately consumes its errno.
  static func exitStatus(controlFD: Int32, read: (Int32) -> (Int, Int32)) -> Int32 {
    while true {
      let (count, error) = read(controlFD)
      if count == 0 { return 0 }
      if count == -1 && error == EINTR { continue }
      return 70
    }
  }
}
