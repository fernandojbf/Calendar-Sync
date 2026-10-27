import Foundation

/// A link to a Homebrew install of the app in the user's own Applications folder, so Finder and
/// the Dock can open it without anyone running `ln -s`. Homebrew can't do it at install time (a
/// formula only writes inside Homebrew's prefix), and the account that logs in to the desktop
/// often can't write to /Applications, but it always owns ~/Applications.
public enum ApplicationsLink {
    public enum Outcome: Equatable {
        /// The link was made.
        case created
        /// One of the folders already has an entry with the app's name: a link, a copy, or a
        /// dangling link someone left. It's left as it is.
        case alreadyThere
    }

    /// Homebrew's opt path for a bundle that Homebrew installed, given the bundle's path with
    /// symlinks resolved: `<prefix>/Cellar/<formula>/<version>/<name>.app` gives
    /// `<prefix>/opt/<formula>/<name>.app`. The opt path keeps pointing at the newest version
    /// after `brew upgrade`, so links go there, never into the cellar. nil for any other bundle.
    public static func homebrewOptBundle(forResolvedBundle bundle: URL) -> URL? {
        let parts = bundle.standardizedFileURL.pathComponents
        guard parts.count >= 5, parts[parts.count - 4] == "Cellar", bundle.pathExtension == "app" else {
            return nil
        }
        let prefix = URL(fileURLWithPath: NSString.path(withComponents: Array(parts.dropLast(4))))
        return prefix
            .appendingPathComponent("opt")
            .appendingPathComponent(parts[parts.count - 3])
            .appendingPathComponent(parts[parts.count - 1])
    }

    /// Links `target` into `folder` under its own name, creating `folder` if needed, unless
    /// `folder` or one of `others` already has an entry with that name. Throws when the link
    /// can't be made.
    public static func ensure(linkTo target: URL, in folder: URL, unlessIn others: [URL] = []) throws -> Outcome {
        let fileManager = FileManager.default
        let name = target.lastPathComponent
        for candidate in [folder] + others {
            // Doesn't follow links, so a dangling one counts as there too.
            let entry = candidate.appendingPathComponent(name)
            if (try? fileManager.attributesOfItem(atPath: entry.path)) != nil { return .alreadyThere }
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            atPath: folder.appendingPathComponent(name).path, withDestinationPath: target.path
        )
        return .created
    }
}
