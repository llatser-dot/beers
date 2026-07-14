import Foundation

/// Where the log actually lives: owner-only (0600), inside the app's own
/// Application Support folder. Transcripts flow through here verbatim, so it
/// must never be world-readable.
private let beersLogRealPath: String = {
    let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Beers", isDirectory: true)
    return base.appendingPathComponent("beers.log").path
}()

/// The legacy path every existing tool, doc and test tails. We keep it working
/// by making it a symlink to the real (owner-only) file — same content, but the
/// bytes are never readable by other users on the machine.
private let beersLogTmpPath = "/tmp/llatser-listen.log"

/// Rotate at ~10 MB so the transcript log can't grow without bound.
private let beersLogMaxBytes: UInt64 = 10 * 1024 * 1024

/// Serialize writes so concurrent pours don't interleave lines or race the
/// symlink/rotation bookkeeping.
private let beersLogQueue = DispatchQueue(label: "com.llatser.listen.log")

func llog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    beersLogQueue.sync { writeBeersLog(data) }
}

private func writeBeersLog(_ data: Data) {
    let fm = FileManager.default
    let path = beersLogRealPath
    let dir = (path as NSString).deletingLastPathComponent

    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    } else {
        // Enforce owner-only even if an older build left it world-readable,
        // and rotate before appending if it's grown past the ceiling.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        rotateBeersLogIfNeeded(path: path, fm: fm)
    }

    ensureBeersTmpSymlink(realPath: path, fm: fm)

    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

private func rotateBeersLogIfNeeded(path: String, fm: FileManager) {
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.uint64Value,
          size >= beersLogMaxBytes else { return }
    let rotated = path + ".1"
    try? fm.removeItem(atPath: rotated)
    try? fm.moveItem(atPath: path, toPath: rotated)
    fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
}

/// Point /tmp/llatser-listen.log at the real owner-only file. Handles the
/// legacy case where /tmp holds a plain (world-readable) regular file: replace
/// it with the symlink once.
private func ensureBeersTmpSymlink(realPath: String, fm: FileManager) {
    let tmp = beersLogTmpPath
    if let dest = try? fm.destinationOfSymbolicLink(atPath: tmp) {
        if dest == realPath { return }   // already the correct symlink
        try? fm.removeItem(atPath: tmp)  // stale/wrong symlink — replace
    } else if fm.fileExists(atPath: tmp) {
        try? fm.removeItem(atPath: tmp)  // legacy regular file — replace once
    }
    try? fm.createSymbolicLink(atPath: tmp, withDestinationPath: realPath)
}
