import Foundation

func llog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/llatser-listen.log"
    guard let data = line.data(using: .utf8) else { return }

    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
