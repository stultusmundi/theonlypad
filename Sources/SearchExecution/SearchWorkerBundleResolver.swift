import Darwin
import Foundation

package enum SearchWorkerBundleResolverError: Error, Equatable, Sendable {
  case invalidURL
  case filesystem(Int32)
}

/// Fixed helper lookup and the launch lane's filesystem check. Neither method launches a process.
package enum SearchWorkerBundleResolver {
  /// Structural lookup only; performs no filesystem or signature inspection.
  package static func candidate(in applicationBundle: URL) throws -> URL {
    let path = try localAbsolutePath(applicationBundle)
    var components: [Substring] = []
    for component in path.split(separator: "/") {
      if component == "." { continue }
      if component == ".." {
        if !components.isEmpty { components.removeLast() }
      } else {
        components.append(component)
      }
    }
    let normalized = "/" + components.joined(separator: "/")
    let separator = components.isEmpty ? "" : "/"
    return URL(
      fileURLWithPath: normalized + separator + "Contents/Helpers/PadSearchWorker",
      isDirectory: false)
  }

  /// Call only on the retained preparation lane, after admission and deadline arming.
  /// Checks the final entry; does not promise ancestor trust or an immutable filesystem snapshot.
  package static func validateForLaunch(_ candidate: URL) throws -> URL {
    let path = try localAbsolutePath(candidate)
    var info = stat()
    guard lstat(path, &info) == 0 else {
      let code = errno
      throw SearchWorkerBundleResolverError.filesystem(code)
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0 else {
      throw SearchWorkerBundleResolverError.filesystem(EACCES)
    }
    guard access(path, X_OK) == 0 else {
      let code = errno
      throw SearchWorkerBundleResolverError.filesystem(code)
    }
    return candidate
  }

  private static func localAbsolutePath(_ url: URL) throws -> String {
    guard url.isFileURL,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "file",
      components.host == nil || components.host == "" || components.host == "localhost",
      components.query == nil, components.fragment == nil,
      let path = components.percentEncodedPath.removingPercentEncoding,
      path.hasPrefix("/"), !path.utf8.contains(0)
    else { throw SearchWorkerBundleResolverError.invalidURL }
    return path
  }
}
