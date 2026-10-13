import Cocoa

/// Spotlight's own switch, for volumes the marker file cannot reach.
///
/// `.metadata_never_index` needs a new file at the volume root, and a Time Machine
/// backup's root refuses one to everybody. `mdutil -i off` reaches the same setting
/// through Spotlight itself, but only as root. The password is asked for by macOS's
/// own prompt - Chokepoint never sees it - and only when the user picks the item.
enum SpotlightAdmin {
    /// What `mdutil -s` says. It needs no privileges to ask.
    enum State { case indexing, off, unknown }

    static func state(of root: String) -> State {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        task.arguments = ["-s", root]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return .unknown }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// "Indexing enabled." / "Indexing disabled." / "Indexing and searching disabled."
    static func parse(_ output: String) -> State {
        let text = output.lowercased()
        if text.contains("disabled") { return .off }
        if text.contains("enabled") { return .indexing }
        return .unknown
    }

    /// Time Machine keeps one of these at the root of a backup volume: the manifest
    /// on APFS destinations, the backup database on the older HFS ones.
    static func isTimeMachine(_ root: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root + "/backup_manifest.plist")
            || fm.fileExists(atPath: root + "/Backups.backupdb")
    }

    /// The shell line, every path single-quoted so a volume called
    /// "nam DDLJ" or "it's mine" is one argument.
    static func command(off: Bool, roots: [String]) -> String {
        let quoted = roots.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return quoted.map { "/usr/bin/mdutil -i \(off ? "off" : "on") \($0)" }
            .joined(separator: " && ")
    }

    /// An AppleScript string literal holding `text`.
    static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs it as root behind the system password prompt. Returns mdutil's own
    /// words on success, or the reason it did not run.
    static func run(off: Bool, roots: [String], names: [String])
        -> (ok: Bool, message: String) {
        let what = names.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        let prompt = off ? "Chokepoint wants to stop Spotlight indexing \(what)."
                         : "Chokepoint wants to let Spotlight index \(what) again."
        let source = "do shell script " + appleScriptLiteral(command(off: off, roots: roots))
            + " with prompt " + appleScriptLiteral(prompt)
            + " with administrator privileges"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            // -128 is the user pressing Cancel: not a failure worth an alert.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return (false, "") }
            return (false, error[NSAppleScript.errorMessage] as? String ?? "mdutil did not run")
        }
        return (true, result?.stringValue ?? "")
    }
}
