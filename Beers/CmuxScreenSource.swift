import AppKit
import Foundation

/// CmuxScreenSource — reads the text of a cmux terminal surface by shelling
/// out to the cmux CLI, which talks to cmux over its local Unix socket.
///
/// Why this exists: cmux renders terminals with xterm.js on a canvas, so its
/// Accessibility tree exposes only an empty helper text area. A pour pasted
/// into cmux can NEVER be found through AX (48/48 anchor failures in the field
/// before this path existed) — the socket is the only faithful view of what is
/// actually on screen. The CLI authenticates itself with the password saved in
/// cmux's own settings, so no credential handling happens here.
///
/// ============================ PRIVACY ================================
/// Identical policy to the AX path: everything read here stays on this
/// machine, feeding only the local flywheel log. The CLI call talks to a
/// user-owned local Unix socket; no network is involved anywhere.
/// ====================================================================
///
/// Threading: `run` spawns the CLI on a utility queue with a hard timeout;
/// completions are always delivered on the main thread.
enum CmuxScreenSource {
    private static let processTimeout: TimeInterval = 3.0
    private static let queue = DispatchQueue(label: "com.llatser.listen.cmux-screen", qos: .utility)

    /// The bundled cmux CLI, resolved from the running cmux app when possible
    /// so we track wherever the user actually keeps it.
    static func cliPath() -> String? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first,
           let bundleURL = app.bundleURL {
            let path = bundleURL.appendingPathComponent("Contents/Resources/bin/cmux").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let fallback = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    static var isAvailable: Bool { cliPath() != nil }

    /// UUID of the terminal surface that currently has focus in cmux, or nil
    /// if the CLI is unavailable, the socket refuses us, or focus is on a
    /// browser surface.
    static func focusedTerminalSurfaceID(completion: @escaping (String?) -> Void) {
        run(args: ["identify", "--no-caller", "--id-format", "uuids"]) { output in
            guard let output,
                  let data = output.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let focused = root["focused"] as? [String: Any],
                  (focused["surface_type"] as? String) == "terminal",
                  (focused["is_browser_surface"] as? Bool) != true,
                  let id = focused["surface_id"] as? String, !id.isEmpty
            else { completion(nil); return }
            completion(id)
        }
    }

    /// Visible screen text of the given surface (no scrollback — the span we
    /// watch was just pasted, so it is on screen; scrollback only adds
    /// duplicate copies that break unique anchoring).
    static func readScreen(surfaceID: String, completion: @escaping (String?) -> Void) {
        run(args: ["read-screen", "--surface", surfaceID], completion: completion)
    }

    /// Run the CLI with a hard timeout. Returns stdout on success, nil on any
    /// failure (missing CLI, non-zero exit, timeout). Never throws, never
    /// blocks the caller.
    private static func run(args: [String], completion: @escaping (String?) -> Void) {
        guard let cli = cliPath() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            queue.asyncAfter(deadline: .now() + processTimeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            let result: String? = process.terminationStatus == 0
                ? String(data: data, encoding: .utf8)
                : nil
            DispatchQueue.main.async { completion(result) }
        }
    }
}
