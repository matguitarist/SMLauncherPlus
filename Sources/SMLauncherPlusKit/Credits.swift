import Foundation

/// Who made the game SM Launcher Plus plays, and under which license (S-006). SM Launcher Plus ships
/// none of it: the game comes from its own GitHub releases, the ROM from the player's Mac.
public enum Credits {
    public static let gameName = "SuperMetroidRecomp"
    public static let gameAuthor = "mstan"
    public static let project = URL(string: "https://github.com/mstan/SuperMetroidRecomp")!
    /// PolyForm Noncommercial 1.0.0, with the extra permissions in PERMISSIONS.md.
    public static let license = URL(string: "https://github.com/mstan/SuperMetroidRecomp/blob/main/LICENSE")!
    public static let permissions = URL(string: "https://github.com/mstan/SuperMetroidRecomp/blob/main/PERMISSIONS.md")!
    public static let licenseName = "PolyForm Noncommercial 1.0.0"
    /// The recompilation framework the game is built on.
    public static let framework = URL(string: "https://github.com/mstan/snesrecomp")!
}
