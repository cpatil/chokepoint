import Foundation

/// Carrying a user's data across the renames: Limen, then Bottleneck, now Chokepoint.
///
/// The app kept everything under an Application Support folder and a preferences
/// domain named after itself, so renaming it would have quietly abandoned both: three
/// hundred logged sessions, the speed catalogue, every setting, and a LaunchAgent
/// still watching /Volumes under the old label. None of that is recoverable by the
/// user afterwards - the files are simply in a folder nothing reads any more - so the
/// rename has to bring them along.
///
/// Runs once, at launch, before anything reads either location. Deliberately a move
/// rather than a copy for the folder, so there is one copy of the log and no question
/// afterwards about which is current; and deliberately a no-op the moment the new
/// folder exists, so it cannot run twice and cannot overwrite live data.
enum Migration {
    /// Every name this app has worn, oldest first.
    ///
    /// A list rather than one previous name, because a second rename would otherwise
    /// strand anyone who skipped the first: someone still on Limen would migrate to a
    /// Bottleneck folder that nothing reads any more. Whoever has data under any of
    /// these gets it carried across in one launch.
    static let previousNames = ["Limen", "Bottleneck"]
    static let newName = "Chokepoint"
    static let previousDomains = ["local.limen", "local.bottleneck"]
    static let newDomain = "local.chokepoint"
    static let previousAgentLabels = ["local.limen.card-watch",
                                      "local.bottleneck.card-watch"]

    /// Whether one file should be carried across: it is in the old folder and the new
    /// folder has nothing by that name. Pure, so the decision can be tested without
    /// moving anything.
    ///
    /// Per file, not per folder. The first version of this asked whether the new
    /// folder existed at all - and the new folder gets created the moment anything
    /// touches the catalogue, including the test suite, so the guard meant to protect
    /// live data would have skipped the move entirely and left five hundred sessions
    /// sitting in a folder nothing reads.
    static func shouldCarry(fileExistsInOld: Bool, fileExistsInNew: Bool) -> Bool {
        fileExistsInOld && !fileExistsInNew
    }

    /// Which of an old domain's keys belong in the new one.
    ///
    /// Per key, for exactly the reason the file carry is per file - and this half did
    /// not learn it the first time. Guarding on the whole new domain being absent
    /// never fires: main.swift reads UserDefaults while building the menu bar, before
    /// applicationDidFinishLaunching runs, and that is enough for the domain to
    /// exist. The rename therefore abandoned every setting in silence - the welcome
    /// screen reappeared, collapsed groups sprang open, and every sort order reset.
    ///
    /// AppKit's own keys are left behind. They carry the app's name in them -
    /// "NSWindow Frame BottleneckWindow" - so under a new name they address a window
    /// that does not exist and are dead weight forever.
    static func keysToCarry(from old: [String: Any], into new: [String: Any]) -> [String] {
        old.keys.filter { !$0.hasPrefix("NS") && new[$0] == nil }.sorted()
    }

    static func run(fileManager: FileManager = .default,
                    defaults: UserDefaults = .standard) {
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask)[0]
        let new = support.appendingPathComponent(newName, isDirectory: true)

        // Newest name first. shouldCarry only moves a file when the destination has
        // nothing by that name, so processing oldest-first would let Limen's stale
        // log win over the Bottleneck one that replaced it.
        for previous in previousNames.reversed() {
            let old = support.appendingPathComponent(previous, isDirectory: true)
            guard let items = try? fileManager.contentsOfDirectory(atPath: old.path)
            else { continue }
            try? fileManager.createDirectory(at: new, withIntermediateDirectories: true)
            for item in items {
                // The lock file belongs to whichever process is running; it is
                // recreated on demand and carrying it across means nothing.
                guard item != "instance.lock" else { continue }
                let from = old.appendingPathComponent(item)
                let to = new.appendingPathComponent(item)
                guard shouldCarry(fileExistsInOld: fileManager.fileExists(atPath: from.path),
                                  fileExistsInNew: fileManager.fileExists(atPath: to.path))
                else { continue }
                try? fileManager.moveItem(at: from, to: to)
            }
            // Left behind only if something could not be moved, which is worth being
            // able to see afterwards rather than silently deleting.
            if (try? fileManager.contentsOfDirectory(atPath: old.path))?
                .filter({ $0 != "instance.lock" }).isEmpty == true {
                try? fileManager.removeItem(at: old)
            }
        }

        // Preferences are a separate store keyed by domain, so they need their own
        // pass. Only what the old app actually wrote: copying the whole domain would
        // drag in AppKit's own window-frame keys under the wrong name.
        //
        // Newest first, and a key already present in the new domain always wins:
        // whatever this launch has written is more current than anything an older
        // name holds.
        var merged = defaults.persistentDomain(forName: newDomain) ?? [:]
        for domain in previousDomains.reversed() {
            guard let carried = defaults.persistentDomain(forName: domain) else { continue }
            for key in keysToCarry(from: carried, into: merged) {
                merged[key] = carried[key]
            }
        }
        if !merged.isEmpty {
            defaults.setPersistentDomain(merged, forName: newDomain)
        }

        // The old watcher would keep running, keep reading the old preferences domain,
        // and keep opening an app that no longer exists there.
        retireOldAgent(fileManager: fileManager)
    }

    /// Unloads and removes the LaunchAgent installed under the old name. The new one
    /// is installed on demand by CardWatch, from the switches carried across above.
    private static func retireOldAgent(fileManager: FileManager) {
        for label in previousAgentLabels {
            let plist = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LaunchAgents/\(label).plist")
            guard fileManager.fileExists(atPath: plist.path) else { continue }
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["unload", plist.path]
            task.standardError = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            try? fileManager.removeItem(at: plist)
        }
    }
}
