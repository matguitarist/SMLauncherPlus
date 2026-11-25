import AppKit
import LogKit
import ProcessKit
import SwiftData
import SMLauncherPlusKit

/// Self-test for agents: drives the app model on a /tmp store, prints PASS or
/// FAIL per check, and quits with exit code 0 or 1.
///   APP_STORE=/tmp/SMLauncherPlus-self.store ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            let before = (try? model.context.fetchCount(FetchDescriptor<Profile>())) ?? -1
            check("the database opens empty", before == 0, "\(before) profiles")
            model.context.insert(Profile(name: "Self-test", gameVersion: "0.4.6"))
            try? model.context.save()
            check("a profile is saved and read back",
                  (try? model.context.fetch(FetchDescriptor<Profile>()))?.map(\.name) == ["Self-test"])
            check("the database file is in the test folder",
                  FileManager.default.fileExists(atPath: Store.url.path) && Store.url.path.hasPrefix("/tmp/"))
            try? model.context.delete(model: Profile.self)
            try? model.context.save()

            // S-001: choosing the ROM
            let folder = URL(fileURLWithPath: "/tmp/SMLauncherPlus-self-roms", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fake = folder.appending(path: "Super Metroid.sfc")
            try? Data(repeating: 0, count: SupportedROM.size).write(to: fake)
            check("the welcome page starts empty", model.welcome == .empty, "\(model.welcome)")
            await model.choose(fake)
            check("a file that isn't a ROM is refused with its reason", model.welcome == .failed(.notROM, fake.lastPathComponent), "\(model.welcome)")
            check("a refused file isn't kept", model.rom == nil)
            try? await Task.sleep(for: .milliseconds(300))  // the log hands lines to the viewer in batches
            check("the refusal is in the log", model.log.entries.contains { $0.source == "ROM" && $0.level == .warning })
            try? FileManager.default.removeItem(at: folder)
            if let real = ProcessInfo.processInfo.environment["SM_ROM_PATH"] {
                let before = Self.dataFiles()
                await model.choose(URL(fileURLWithPath: real))
                check("the player's ROM is accepted", model.welcome == .ready, "\(model.welcome)")
                check("the ROM is kept with its bookmark", model.rom?.bookmark != nil && model.rom?.url.path == real)
                check("the ROM is still chosen after a restart",
                      AppModel(container: model.container).welcome == .ready && AppModel(container: model.container).rom?.path == real)
                check("the ROM is never copied", Self.dataFiles() == before)
            } else {
                print("SKIP the player's ROM: set SM_ROM_PATH to check it")
            }

            // S-002: downloading the game. Offline first, on a pretend ROM, then the real download when asked.
            let hadROM = model.rom != nil
            if !hadROM {
                model.context.insert(RomSource(rom: ROMCheck.ROM(url: URL(fileURLWithPath: "/tmp/none.sfc"), kind: .file, member: "",
                                                                 headered: false, sha256: SupportedROM.sha256)))
            }
            AppModel.simulateOffline = true
            model.startInstall()
            await Self.waitForInstall(model)
            check("offline, the install says GitHub can't be reached",
                  model.install?.failure == GameRelease.Failure.offline.message && model.install?.step == .download)
            check("offline, nothing is left in Downloads", Self.files(in: DataFolder.downloads).isEmpty)
            model.cancelInstall()
            check("Cancel on a failed install goes back to the welcome page", model.install == nil)
            AppModel.simulateOffline = false
            if ProcessInfo.processInfo.environment["APP_SELFTEST_INSTALL"] == "1" {
                model.startInstall()
                model.cancelInstall()
                await Self.waitForInstall(model)
                check("Cancel stops the download and removes its partial file",
                      model.install == nil && !Self.files(in: DataFolder.downloads).contains { $0.hasSuffix(".partial") })
                model.startInstall()
                await Self.waitForInstall(model)
                let zips = Self.files(in: DataFolder.downloads).filter { $0.hasSuffix("-macos-\(GameRelease.architecture).zip") }
                check("the latest build downloads, matches its checksum and is kept in Downloads/<version>/",
                      zips.count == 1, model.install?.failure ?? "\(Self.files(in: DataFolder.downloads))")
                // S-003: the profile
                let profiles = (try? model.context.fetch(FetchDescriptor<Profile>())) ?? []
                check("the install adds one profile named Super Metroid",
                      profiles.count == 1 && profiles.first?.name == String(localized: "Super Metroid"), "\(profiles.map(\.name))")
                if let profile = profiles.first {
                    check("the Play page opens on the new profile",
                          model.install == nil && model.sidebar == .play && model.currentProfile?.uuid == profile.uuid && !model.forceWelcome)
                    check("the game is unpacked into Profiles/<id>/game/",
                          FileManager.default.isExecutableFile(atPath: profile.executable.path))
                    let info = ProfileBuilder.Info.read(from: profile.folder)
                    check("profile.json records the version and the ROM",
                          info?.version == profile.gameVersion && info?.romSHA256 == SupportedROM.sha256)
                    check("the game has no quarantine flag", !ProfileBuilder.isQuarantined(profile.executable))
                    check("the launcher's filters are added beside the game's own",
                          Set(ShaderPreset.list(game: profile.gameFolder).map(\.look))
                            .isSuperset(of: ["scanlines", "crt", "sharp", "crt-soft", "lcd-grid", "warm-composite"]),
                          "\(ShaderPreset.list(game: profile.gameFolder).map(\.path))")
                    let help = await Self.runHeadless(profile.executable, ["--help"])
                    check("the game runs right after unpacking (--help)", help.status == 0 && help.output.contains("usage:"),
                          "exit \(help.status): \(help.output.prefix(200))")
                }
                model.startInstall()
                await Self.waitForInstall(model)
                check("a verified download is reused",
                      model.log.entries.contains { $0.message.hasPrefix("Using the downloaded") })
                // S-031: the real release installed over a profile that says it's older keeps its save.
                if let profile = model.currentProfile {
                    let latest = profile.gameVersion
                    let save = profile.gameFolder.appending(path: "saves/selftest.srm")
                    try? FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Data("samus".utf8).write(to: save)
                    profile.gameVersion = "0.0.1"
                    await model.checkForGameUpdate(force: true)
                    check("an older profile can be updated", model.canUpdate, "latest \(model.latestUpdate?.version ?? "none")")
                    model.update(profile)
                    check("Update shows the install page for this profile", model.install?.updating == profile.uuid)
                    await Self.waitForInstall(model)
                    check("Update finishes on the latest version, in the same profile, with the save",
                          model.install == nil && profile.gameVersion == latest
                          && (try? String(contentsOf: save, encoding: .utf8)) == "samus"
                          && FileManager.default.isExecutableFile(atPath: profile.executable.path),
                          model.install?.failure ?? profile.gameVersion)
                    check("the build from before the update is kept for Roll Back", model.previousVersion(of: profile) == latest)
                    check("Update backs up the saves first", SaveBackup.list(in: DataFolder.backups(for: profile.uuid))
                        .contains { $0.name.hasSuffix("(\(String(localized: "before update to \(latest)")))") })
                    try? FileManager.default.removeItem(at: ProfileUpdate.previousFolder(of: profile.folder))
                    await Self.checkRetroArchFilters(model: model, profile: profile)
                }
                if model.rom != nil, ProcessInfo.processInfo.environment["SM_ROM_PATH"] != nil {
                    await Self.checkPlay(model)
                } else {
                    print("SKIP Play: needs SM_ROM_PATH")
                }
            } else {
                print("SKIP the real download: set APP_SELFTEST_INSTALL=1 to download the game from GitHub")
            }
            if !hadROM {
                try? model.context.delete(model: RomSource.self)
                try? model.context.save()
            }

            model.log.post(.info, "Self-test line", source: "SelfTest")
            try? await Task.sleep(for: .milliseconds(300))
            check("the app writes a log line", model.log.entries.contains { $0.message == "Self-test line" })
            let file = (try? String(contentsOf: Store.logURL, encoding: .utf8)) ?? ""
            check("the log line reaches the log file", file.contains("Self-test line"))

            for item in SidebarItem.allCases {
                model.sidebar = item
                try? await Task.sleep(for: .milliseconds(200))
                check("the \(item.rawValue) page opens", model.sidebar == item)
            }
            for tab in SettingsTab.allCases {
                model.settingsTab = tab
                check("the \(tab.rawValue) Settings tab is selectable", model.settingsTab == tab)
            }
            // S-012: the Controls tab names what GameController sees.
            let pads = ControllerMonitor().names
            check("a connected controller is named", pads == ControllerMonitor.connected(),
                  pads.isEmpty ? "none connected" : pads.joined(separator: ", "))
            // S-006: About credits the game, its version and its license.
            let about = AboutCredits.make(gameVersion: "0.4.6")
            var links = Set<URL>()
            about.enumerateAttribute(.link, in: NSRange(location: 0, length: about.length)) { value, _, _ in
                if let url = value as? URL { links.insert(url) }
            }
            check("About shows the installed game version", about.string.contains("0.4.6"), about.string)
            check("About links to the game, its license and snesrecomp",
                  links == [Credits.project, Credits.license, Credits.framework], "\(links)")

            await checkUpdateBanner(model: model)
            await checkUpdateAndRollBack(model: model)
            await checkManageProfiles(model: model)
            await checkSaveBackups(model: model)
            await checkDataFolderMove(model: model)
            await checkModInstall(model: model)
            await checkModResources()

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// S-004: Play starts the game straight to the title screen, then Stop records the time and removes the ROM copy.
    /// The game runs headless and dumps each frame's RAM; Super Metroid's game state ($0998) is 1 on the title screen.
    private static func checkPlay(_ model: AppModel) async {
        guard let profile = model.currentProfile else { return check("Play has a profile", false, "") }
        let frames = FileManager.default.temporaryDirectory.appending(path: "SMLauncherPlus-frames-\(UUID())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: frames) }
        // S-020: the game's own packages, and choices written the way the game writes them.
        let mods = ModsModel(game: profile.gameFolder)
        let stateFile = mods.root.appending(path: "state.toml")
        Self.check("the Mods page reads the game's packages", mods.packages.count >= 5, "\(mods.packages.map(\.id))")
        let features = mods.packages.flatMap(\.features)
        let introSkip = features.first { $0.key == "super-metroid.pacing/intro-skip" }
        let elevators = features.first { $0.key == "super-metroid.pacing/elevators" }
        if let introSkip, let elevators, let speed = elevators.options.first(where: { $0.id == "speed" }) {
            mods.setEnabled(true, introSkip) { _ in }
            mods.setEnabled(true, elevators) { _ in }
            mods.setValue("3x", of: speed, in: elevators) { _ in }
        }
        Self.check("Skippable intro and Faster elevators (3x) are saved",
                   introSkip != nil && ModState.read(from: mods.root).isEnabled(introSkip!) && mods.error == nil)
        // S-010: display settings written where the game reads them.
        var display = DisplaySettings.read(game: profile.gameFolder)
        let presets = ShaderPreset.list(game: profile.gameFolder)
        check("the filter list comes from the game's own shaders", presets.contains { $0.look == "crt" } && presets.contains { $0.look == "scanlines" },
              "\(presets.map(\.path))")
        display.widescreen = .ultrawide
        display.hudAtEdges = false
        display.shader = presets.first { $0.look == "crt" && $0.strength == "strong" }?.path ?? ""
        do { try display.write(game: profile.gameFolder) } catch { check("display settings are saved", false, "\(error)") }
        check("display settings read back as written", DisplaySettings.read(game: profile.gameFolder) == display)
        // S-011: sound settings written to config.ini, clamped, beside the game's other [Sound] keys.
        var sound = SoundSettings.read(game: profile.gameFolder)
        sound.volume = 145
        do { try sound.write(game: profile.gameFolder) } catch { check("sound settings are saved", false, "\(error)") }
        let soundConfig = IniFile(text: (try? String(contentsOf: DisplaySettings.configFile(game: profile.gameFolder), encoding: .utf8)) ?? "")
        check("volume is clamped to 100 and the game's other sound keys stay",
              soundConfig.value("Volume", in: "Sound") == "100" && soundConfig.value("AudioFreq", in: "Sound") != nil,
              soundConfig.value("Volume", in: "Sound") ?? "no Volume")
        sound.volume = 80
        do { try sound.write(game: profile.gameFolder) } catch { check("sound settings are saved", false, "\(error)") }
        check("sound settings read back as written", SoundSettings.read(game: profile.gameFolder) == sound)
        // S-012: player 1's keys in keybinds.ini and controller buttons in config.ini.
        var controls = ControlSettings.read(game: profile.gameFolder)
        let configBefore = (try? String(contentsOf: DisplaySettings.configFile(game: profile.gameFolder), encoding: .utf8)) ?? ""
        do { try controls.write(game: profile.gameFolder) } catch { check("controls are saved", false, "\(error)") }
        check("unchanged controls leave config.ini as it was",
              (try? String(contentsOf: DisplaySettings.configFile(game: profile.gameFolder), encoding: .utf8)) == configBefore)
        controls.keys[.b] = "Space"
        controls.buttons[.l] = "L2"
        do { try controls.write(game: profile.gameFolder) } catch { check("controls are saved", false, "\(error)") }
        check("controls read back as written", ControlSettings.read(game: profile.gameFolder) == controls)
        // S-022: the Zero Mission map art chosen inside the player's .zip (SM_GBA_ZIP), read in place.
        let gbaZip = ProcessInfo.processInfo.environment["SM_GBA_ZIP"]
        let pauseMap = mods.packages.flatMap(\.features).first { $0.key == "super-metroid.map-hud/pause-map" }
        if let gbaZip, let pauseMap, let art = pauseMap.resources.first {
            mods.setEnabled(true, pauseMap) { _ in }
            mods.setPath(gbaZip, of: art, in: pauseMap) { _ in }
            await mods.checkResource(art, in: pauseMap)
            check("the Zero Mission ROM inside its .zip is recognized", mods.status(of: art, in: pauseMap) == .verified,
                  "\(String(describing: mods.status(of: art, in: pauseMap)))")
        } else if gbaZip == nil {
            print("SKIP the Zero Mission map art: set SM_GBA_ZIP to your zipped Metroid: Zero Mission (USA) ROM")
        }
        let before = profile.playTime
        model.play(extraArguments: ["--framedump", frames.path], environment: ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"])
        check("Play starts the game", model.isPlaying, model.playFailure?.message ?? "")
        guard let game = model.game else { return }
        if gbaZip != nil, pauseMap != nil {
            let during = ModState.read(from: mods.root).sharedResources["metroid.zero-mission-us"] ?? ""
            check("for the run, the game is pointed at a private unpacked copy",
                  during.hasPrefix(DataFolder.runROM.resolvingSymlinksInPath().path) || during.hasPrefix(DataFolder.runROM.path), during)
        }
        let copies = Self.files(in: DataFolder.runROM).filter { $0.hasSuffix(".sfc") }
        let zipped = model.rom.map { $0.kindRaw != ROMCheck.Kind.file.rawValue || $0.headered } ?? false
        check("a zipped ROM is unpacked privately for the run, a plain one is passed in place",
              zipped ? copies.count == 1 : copies.isEmpty, "\(copies)")
        var title = false
        let deadline = Date.now.addingTimeInterval(30)
        while !title, game.isRunning, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            title = Self.reachedTitle(in: frames)
        }
        check("the game boots past its own launcher to the title screen", title,
              (try? String(contentsOf: game.log, encoding: .utf8).suffix(400)).map(String.init) ?? "")
        let arguments = (try? String(contentsOf: game.log, encoding: .utf8)) ?? ""
        check("the game read the profile's config.ini", arguments.contains("config parsed"))
        check("the game read the keys from keybinds.ini", arguments.contains("[Keybinds] Loaded"),
              arguments.components(separatedBy: "\n").first { $0.contains("Keybinds") } ?? "no Keybinds line")
        check("the game uses the widescreen shape and HUD place from the Display tab",
              arguments.contains("custom renderer: 1 aspect=21:9") && arguments.contains("hud=0"),
              arguments.components(separatedBy: "\n").first { $0.contains("custom renderer") } ?? "no renderer line")
        check("the game turns on the features chosen on the Mods page",
              arguments.contains("[mods] intro skip: 1/1") && arguments.contains("[mods] elevators 3x"),
              arguments.components(separatedBy: "\n").filter { $0.hasPrefix("[mods]") }.joined(separator: " | "))
        // The game rewrites state.toml when it starts: the launcher's reading and writing must give back the same text.
        let original = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        let rewritten = ModState.parse(original).text()
        let difference = zip(original.components(separatedBy: "\n"), rewritten.components(separatedBy: "\n"))
            .enumerated().first { $0.element.0 != $0.element.1 }
            .map { "line \($0.offset + 1): \($0.element.0) → \($0.element.1)" } ?? "\(original.count) vs \(rewritten.count) characters"
        check("the launcher writes state.toml exactly as the game does", !original.isEmpty && rewritten == original, difference)
        check("the game keeps the launcher's choices", original.contains("speed = \"3x\""))
        model.stopGame()
        let stopDeadline = Date.now.addingTimeInterval(10)
        while model.isPlaying, Date.now < stopDeadline { try? await Task.sleep(for: .milliseconds(100)) }
        check("Stop ends the game and Play comes back", !model.isPlaying)
        check("play time and last played are saved", profile.playTime > before && profile.lastPlayedAt != nil,
              "\(profile.playTime)")
        check("the temporary ROM copy is deleted when the game quits",
              Self.files(in: DataFolder.runROM).isEmpty, "\(Self.files(in: DataFolder.runROM))")
        if let gbaZip, pauseMap != nil {
            let after = ModState.read(from: mods.root).sharedResources["metroid.zero-mission-us"]
            check("after the run, state.toml names the .zip again", after == gbaZip, after ?? "none")
            let lines = ((try? String(contentsOf: game.log, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            check("the game loads the Zero Mission map art", lines.contains { $0.contains("Zero Mission donor map tiles/palette loaded") },
                  lines.filter { $0.hasPrefix("[mods]") }.joined(separator: " | "))
        }
        // S-005
        check("Stop isn't reported as a problem", model.lastGameFailure == nil)
        let reported = GameReport.files(game: profile.gameFolder, sessionLog: game.log, pid: game.pid).map(\.lastPathComponent)
        check("a report takes the run's replay files and its run report",
              reported.contains { $0.hasSuffix(".replay") } && reported.contains { $0.hasSuffix(".replay.sav") }
                && reported.contains("last_run_report.json"), "\(reported)")
        model.play(extraArguments: ["--no-such-option"], environment: ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"])
        let failDeadline = Date.now.addingTimeInterval(15)
        while model.isPlaying, Date.now < failDeadline { try? await Task.sleep(for: .milliseconds(100)) }
        check("a game that quits with an error shows the banner", model.lastGameFailure?.status == 2,
              "\(String(describing: model.lastGameFailure))")
        model.showGameLog()
        check("Show Log opens the run's log", model.logSheet?.log == model.lastGameFailure?.log && model.logSheet != nil)
        model.logSheet = nil
        if let zip = model.reportProblem(reveal: false) {
            let names = Self.zipNames(zip)
            check("Report a Problem saves a zip with the log and about.txt, never the ROM",
                  names.contains("about.txt") && names.contains { $0.hasSuffix(".log") }
                    && !names.contains { ["sfc", "smc", "zip"].contains(($0 as NSString).pathExtension.lowercased()) }, "\(names)")
        } else {
            check("Report a Problem saves a zip", false, model.reportError ?? "")
        }
        model.play(extraArguments: ["--help"], environment: ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"])
        check("Play clears the banner", model.lastGameFailure == nil)
        while model.isPlaying { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private static func zipNames(_ zip: URL) -> [String] {
        (try? Shell.runSync("/usr/bin/zipinfo", ["-1", zip.path]))?.lines ?? []
    }

    /// True once a dumped frame shows game state 1 (title screen) at $0998.
    private static func reachedTitle(in frames: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasSuffix("_wram.bin") }.sorted()
        // Only the newest few; earlier ones are deleted to keep the dump small.
        for name in names.dropLast(3) { try? FileManager.default.removeItem(at: frames.appending(path: name)) }
        for name in names.suffix(3).reversed() {
            guard let data = try? Data(contentsOf: frames.appending(path: name)), data.count > 0x999 else { continue }
            if data[0x998] == 1, data[0x999] == 0 { return true }
        }
        return false
    }

    /// Runs the game with SDL's dummy video and audio, for at most 20 seconds.
    private static func runHeadless(_ executable: URL, _ arguments: [String]) async -> (status: Int32, output: String) {
        let options = Shell.Options(directory: executable.deletingLastPathComponent(),
                                    environment: ["SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"],
                                    stderr: .merged, timeout: .seconds(20))
        do {
            let output = try await Shell.run(executable.path, arguments, options: options)
            return (output.status, output.text)
        } catch ShellError.timedOut {
            return (-2, "timed out")
        } catch {
            return (-1, "\(error)")
        }
    }

    /// Waits until the install task finishes (up to two minutes, for a real download).
    private static func waitForInstall(_ model: AppModel) async {
        for _ in 0..<1200 where model.installTask != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// S-013: profiles and downloads follow the data folder to another place and back; a refused move changes nothing.
    private static func checkDataFolderMove(model: AppModel) async {
        let fm = FileManager.default
        let profile = Profile(name: "Moving", gameVersion: "0.4.6")
        model.context.insert(profile)
        try? model.context.save()
        try? fm.createDirectory(at: profile.gameFolder, withIntermediateDirectories: true)
        try? Data("save".utf8).write(to: profile.gameFolder.appending(path: "saves.srm"))
        let download = DataFolder.downloads.appending(path: "selftest/game.zip")
        try? fm.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("zip".utf8).write(to: download)
        let original = DataFolder.url
        let before = files(in: original)

        await model.moveDataFolder(into: original.appending(path: "Profiles"))
        check("a move into the data folder itself is refused, nothing changes",
              model.dataMoveError != nil && DataFolder.url == original && files(in: original) == before, model.dataMoveError ?? "no error")

        let target = URL(fileURLWithPath: "/tmp/SMLauncherPlus-self-move-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        await model.moveDataFolder(into: target)
        check("the data folder moves", model.dataMoveError == nil
              && DataFolder.url.deletingLastPathComponent().path == target.resolvingSymlinksInPath().path, model.dataMoveError ?? DataFolder.url.path)
        check("profiles and downloads follow the data folder", files(in: DataFolder.url) == before
              && fm.fileExists(atPath: profile.gameFolder.appending(path: "saves.srm").path), "\(files(in: DataFolder.url))")
        check("the old data folder is gone", !fm.fileExists(atPath: original.path))
        check("the database stays where it was", fm.fileExists(atPath: Store.url.path)
              && (try? model.context.fetchCount(FetchDescriptor<Profile>())) ?? 0 > 0)
        check("pages are rebuilt after a move", model.dataFolderMoves == 1)

        await model.moveDataFolder(into: original.deletingLastPathComponent())
        check("the data folder moves back", DataFolder.testLocation == nil && files(in: original) == before, DataFolder.url.path)
        try? fm.removeItem(at: target)
        try? fm.removeItem(at: profile.folder)
        try? fm.removeItem(at: download.deletingLastPathComponent())
        model.context.delete(profile)
        try? model.context.save()
        model.dataMoveError = nil
    }

    /// S-021: a .snesmod made with zip installs into a profile, shows as the player's, and is removed with its choices.
    private static func checkModInstall(model: AppModel) async {
        let fm = FileManager.default
        let profile = Profile(name: "Mods", gameVersion: "0.4.6")
        model.context.insert(profile)
        try? model.context.save()
        let mods = ModsModel(game: profile.gameFolder)
        try? fm.createDirectory(at: mods.root.appending(path: "packages"), withIntermediateDirectories: true)
        let work = URL(fileURLWithPath: "/tmp/SMLauncherPlus-self-snesmod-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        func pack(_ name: String, game: String) -> URL {
            let source = work.appending(path: name, directoryHint: .isDirectory)
            try? fm.createDirectory(at: source.appending(path: "art"), withIntermediateDirectories: true)
            try? """
            format_version = 1
            id = "selftest.hud"
            version = "1.0.0"
            name = "Self-test HUD"
            [[target]]
            game_id = "\(game)"
            rom_sha256 = "\(SupportedROM.sha256)"
            [[feature]]
            id = "clock"
            name = "Clock"
            group = "HUD"
            """.write(to: source.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
            try? Data(repeating: 1, count: 50_000).write(to: source.appending(path: "art/clock.bin"))
            let archive = work.appending(path: "\(name).snesmod")
            _ = try? Shell.runSync("/usr/bin/zip", ["-q", "-r", "-X", archive.path, "."], in: source)
            return archive
        }
        await model.installMod(pack("hud", game: ModCatalog.gameID), in: profile, mods: mods)
        check("a .snesmod installs into the profile", mods.packages.contains { $0.id == "selftest.hud" }
              && fm.fileExists(atPath: mods.root.appending(path: "packages/selftest.hud/1.0.0/art/clock.bin").path),
              model.modMessage?.text ?? "no message")
        check("it's listed as the player's package", mods.installed(in: profile).map(\.id) == ["selftest.hud"]
              && model.modMessage == .installed(name: "Self-test HUD", version: "1.0.0"))
        await model.installMod(pack("hud", game: ModCatalog.gameID), in: profile, mods: mods)
        check("the same version again is refused", model.modMessage == .failed(ModArchive.Failure.alreadyInstalled(name: "Self-test HUD", version: "1.0.0").message))
        await model.installMod(pack("other", game: "smw-usa"), in: profile, mods: mods)
        check("a package for another game is refused with the reason",
              model.modMessage?.text.contains("smw-usa") == true && model.modMessage?.isFailure == true, model.modMessage?.text ?? "")
        if let feature = mods.packages.first(where: { $0.id == "selftest.hud" })?.features.first {
            mods.setEnabled(true, feature) { _ in }
        }
        if let package = mods.packages.first(where: { $0.id == "selftest.hud" }) {
            model.removeMod(package, from: profile, mods: mods)
        }
        let state = (try? String(contentsOf: mods.root.appending(path: "state.toml"), encoding: .utf8)) ?? ""
        check("Remove deletes the package and its choices", !fm.fileExists(atPath: mods.root.appending(path: "packages/selftest.hud").path)
              && !state.contains("selftest.hud") && profile.installedMods.isEmpty && model.modMessage == .removed(name: "Self-test HUD"), state)
        model.modMessage = nil
        try? fm.removeItem(at: profile.folder)
        model.context.delete(profile)
        try? model.context.save()
    }

    /// S-030: the banner shows only for a newer version, with the notes of every version since the profile's.
    private static func checkUpdateBanner(model: AppModel) async {
        let profile = Profile(name: "Update", gameVersion: "0.4.6")
        model.context.insert(profile)
        try? model.context.save()
        let saved = model.latestUpdate
        let latest = SeedData.latestUpdate()
        model.latestUpdate = latest
        check("a newer release shows the banner", model.availableUpdate(for: profile)?.version == "0.4.8")
        check("What's New lists every version since the profile's", latest.notes(since: profile.gameVersion).map(\.version) == ["0.4.8", "0.4.7"])
        profile.gameVersion = "0.4.8"
        check("the latest version shows no banner", model.availableUpdate(for: profile) == nil)
        // Offline, a forced check says why and keeps the last answer.
        let wasOffline = AppModel.simulateOffline
        AppModel.simulateOffline = true
        await model.checkForGameUpdate(force: true)
        AppModel.simulateOffline = wasOffline
        check("an offline check says why and keeps the last answer",
              model.updateCheckMessage == GameRelease.Failure.offline.message && model.latestUpdate == latest, model.updateCheckMessage ?? "")
        model.updateCheckMessage = nil
        model.latestUpdate = saved
        if ProcessInfo.processInfo.environment["APP_SELFTEST_INSTALL"] == "1" {
            await model.checkForGameUpdate(force: true)
            let live = model.latestUpdate
            check("GitHub answers with the latest release and its notes",
                  live != nil && live?.version.isEmpty == false && live?.notes.first?.version == live?.version && live?.notes.first?.body.isEmpty == false,
                  model.updateCheckMessage ?? "\(String(describing: live?.version))")
            check("the answer is kept for the next launch", UpdateCheck.read(from: DataFolder.latestUpdate) == live)
        }
        model.context.delete(profile)
        try? model.context.save()
    }

    /// S-031: an update keeps the player's files and the old build; Roll Back brings that build back
    /// with the saves made since. Made-up release zips, no network.
    private static func checkUpdateAndRollBack(model: AppModel) async {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: "/tmp/SMLauncherPlus-self-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        func release(_ version: String) -> URL? {
            let top = work.appending(path: "src-\(version)/supermetroid-\(version)-macos-arm64", directoryHint: .isDirectory)
            try? fm.createDirectory(at: top.appending(path: "mods/preloaded/packages/super-metroid.combat/\(version)"), withIntermediateDirectories: true)
            try? Data("\(version)\n".utf8).write(to: top.appending(path: "VERSION"))
            try? Data("[General]\nScale = 2\n".utf8).write(to: top.appending(path: "config.ini"))
            try? Data("combat".utf8).write(to: top.appending(path: "mods/preloaded/packages/super-metroid.combat/\(version)/manifest.toml"))
            try? Data("#!/bin/sh\n".utf8).write(to: top.appending(path: ProfileBuilder.executable))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: top.appending(path: ProfileBuilder.executable).path)
            let zip = work.appending(path: "\(version).zip")
            let zipped = try? Shell.runSync("/usr/bin/zip", ["-q", "-r", "-y", zip.path, top.lastPathComponent], in: top.deletingLastPathComponent())
            return zipped?.succeeded == true ? zip : nil
        }
        guard let old = release("0.4.6"), let new = release("0.4.7") else { return check("made-up releases are zipped", false) }
        let profile = Profile(name: "Updating", gameVersion: "0.4.6")
        profile.installedMods = ["fan.hud/1.0.0"]
        model.context.insert(profile)
        try? model.context.save()
        defer { try? fm.removeItem(at: profile.folder); model.context.delete(profile); try? model.context.save() }
        do {
            try ProfileBuilder.build(zip: old, profile: profile.folder, info: .init(version: "0.4.6", romSHA256: SupportedROM.sha256))
        } catch {
            return check("a made-up 0.4.6 profile is built", false, "\(error)")
        }
        let game = profile.gameFolder
        for (path, text) in ["saves/save.srm": "samus", "config.ini": "[General]\nScale = 4\n",
                             "mods/preloaded/state.toml": "format_version = 1\n",
                             "mods/preloaded/packages/fan.hud/1.0.0/manifest.toml": "hud"] {
            try? fm.createDirectory(at: game.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: game.appending(path: path))
        }
        check("a profile that was never updated has nothing to roll back to", model.previousVersion(of: profile) == nil)
        let keeping = Set(profile.installedMods.compactMap { $0.split(separator: "/").first.map(String.init) })
        let updated = try? ProfileUpdate.update(zip: new, profile: profile.folder, info: .init(version: "0.4.7", romSHA256: SupportedROM.sha256),
                                                keepingPackages: keeping)
        profile.gameVersion = updated?.version ?? profile.gameVersion
        func text(_ path: String) -> String? { try? String(contentsOf: game.appending(path: path), encoding: .utf8) }
        check("Update keeps the saves, config.ini values, mod choices and the player's packages",
              text("VERSION") == "0.4.7\n" && text("saves/save.srm") == "samus"
              && IniFile(text: text("config.ini") ?? "").value("Scale", in: "General") == "4"
              && text("mods/preloaded/state.toml") == "format_version = 1\n"
              && text("mods/preloaded/packages/fan.hud/1.0.0/manifest.toml") == "hud"
              && !fm.fileExists(atPath: game.appending(path: "mods/preloaded/packages/super-metroid.combat/0.4.6").path),
              "\(files(in: game))")
        check("the old build is kept for Roll Back", model.previousVersion(of: profile) == "0.4.6")
        try? Data("samus in 0.4.7".utf8).write(to: game.appending(path: "saves/save.srm"))
        await model.rollBack(profile)
        check("Roll Back returns to the previous version with the newer save",
              profile.gameVersion == "0.4.6" && text("VERSION") == "0.4.6\n" && text("saves/save.srm") == "samus in 0.4.7"
              && model.previousVersion(of: profile) == nil, model.updateCheckMessage ?? "")
        model.updateCheckMessage = nil
    }

    /// S-032: rename, duplicate, and delete with or without the saves.
    private static func checkManageProfiles(model: AppModel) async {
        let fm = FileManager.default
        let original = Profile(name: "Managed", gameVersion: "0.4.11")
        model.context.insert(original)
        try? model.context.save()
        for path in ["saves/save.srm", "config.ini", ProfileBuilder.executable] {
            let file = original.gameFolder.appending(path: path)
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(path.utf8).write(to: file)
        }
        model.rename(original, to: "  My   Run ")
        check("Rename cleans the name", original.name == "My Run")
        model.rename(original, to: "   ")
        check("an empty name becomes Super Metroid", original.name == String(localized: "Super Metroid"))
        model.rename(original, to: "My Run")
        let copy = await model.duplicate(original)
        check("Duplicate adds a copy and puts it on the Play page", copy?.name == "My Run \(String(localized: "Copy"))"
              && model.currentProfile?.uuid == copy?.uuid, copy?.name ?? "none")
        if let copy {
            check("the copy has the game, saves and settings", fm.fileExists(atPath: copy.gameFolder.appending(path: "saves/save.srm").path)
                  && fm.fileExists(atPath: copy.gameFolder.appending(path: "config.ini").path) && copy.gameVersion == original.gameVersion)
            model.deleteTarget = copy
            check("Delete asks first", fm.fileExists(atPath: copy.folder.path) && model.profiles.contains { $0.uuid == copy.uuid })
            model.deleteTarget = nil
            let folder = copy.folder
            model.delete(copy, keepSaves: false)
            check("Delete without the saves removes the profile and its files",
                  !fm.fileExists(atPath: folder.path) && !model.profiles.contains { $0.name == "My Run \(String(localized: "Copy"))" })
            check("the Play page goes back to another profile", model.currentProfile != nil)
        }
        let folder = original.folder, id = original.uuid
        model.delete(original, keepSaves: true)
        var keptFolder: URL?
        if case .kept(_, let folder) = model.profileMessage { keptFolder = folder }
        check("Delete, Keep Saves moves the saves and settings to Kept Saves",
              keptFolder.map { fm.fileExists(atPath: $0.appending(path: "saves/save.srm").path) && fm.fileExists(atPath: $0.appending(path: "config.ini").path) } == true
              && keptFolder?.deletingLastPathComponent().lastPathComponent == "Kept Saves", keptFolder?.path ?? "none")
        check("the deleted profile and its files are gone", !fm.fileExists(atPath: folder.path) && !model.profiles.contains { $0.uuid == id })
        if let keptFolder { try? fm.removeItem(at: keptFolder) }
        model.profileMessage = nil
    }

    /// S-014: the real download from GitHub, the files in the profile, the Filter menu, and Remove.
    private static func checkRetroArchFilters(model: AppModel, profile: Profile) async {
        await model.downloadRetroArchFilters()
        check("Download fetches every RetroArch filter file and checks it", model.hasRetroArchFilters, model.retroArchError ?? "")
        let looks = ShaderPreset.list(game: profile.gameFolder).compactMap(\.retroArch)
        check("the RetroArch filters are added to the profile, after the launcher's", looks == RetroArchFilter.all,
              looks.map(\.id).joined(separator: ", "))
        var settings = DisplaySettings.read(game: profile.gameFolder)
        settings.shader = RetroArchFilter.all[0].shaderPath
        try? settings.write(game: profile.gameFolder)
        model.removeRetroArchFilters()
        check("Remove takes them out of every profile, and a profile using one goes back to none",
              !model.hasRetroArchFilters && ShaderPreset.list(game: profile.gameFolder).allSatisfy { $0.retroArch == nil }
              && DisplaySettings.read(game: profile.gameFolder).shader.isEmpty)
    }

    /// S-033: Back Up Saves, then Restore, which backs up the current saves first.
    private static func checkSaveBackups(model: AppModel) async {
        let fm = FileManager.default
        let profile = Profile(name: "Backed", gameVersion: "0.4.11")
        model.context.insert(profile)
        try? model.context.save()
        let saves = SaveBackup.saves(game: profile.gameFolder)
        try? fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let backups = DataFolder.backups(for: profile.uuid)
        let none = await model.backUpSaves(profile)
        check("a profile with no saves says so", none == nil && model.backupError == SaveBackup.Failure.noSaves.message, model.backupError ?? "")
        try? Data("samus".utf8).write(to: saves.appending(path: "save.srm"))
        let zip = await model.backUpSaves(profile)
        check("Back Up Saves zips the saves into Backups/<id>/", zip.map { fm.fileExists(atPath: $0.path) && $0.deletingLastPathComponent() == backups } == true,
              model.backupError ?? "")
        try? Data("samus later".utf8).write(to: saves.appending(path: "save.srm"))
        if let zip { await model.restoreSaves(profile, from: zip) }
        check("Restore puts the backup back", (try? String(contentsOf: saves.appending(path: "save.srm"), encoding: .utf8)) == "samus",
              model.backupError ?? "")
        check("Restore backs up the saves it replaces", SaveBackup.list(in: backups).count == 2
              && SaveBackup.list(in: backups).contains { $0.name.hasSuffix("(\(String(localized: "before restore")))") })
        model.delete(profile, keepSaves: false)
        check("deleting a profile deletes its backups", !fm.fileExists(atPath: backups.path))
        model.backupMessage = nil
        model.backupError = nil
    }

    /// S-022: a required file keeps its feature off until it's chosen and checked; a shared file is chosen once.
    private static func checkModResources() async {
        let fm = FileManager.default
        let game = URL(fileURLWithPath: "/tmp/SMLauncherPlus-self-resources-\(UUID().uuidString)/game", isDirectory: true)
        defer { try? fm.removeItem(at: game.deletingLastPathComponent()) }
        let art = game.deletingLastPathComponent().appending(path: "art.gba")
        try? fm.createDirectory(at: game, withIntermediateDirectories: true)
        try? Data(repeating: 9, count: 32768).write(to: art)
        let hash = ModResource.normalizedSHA256(of: art) ?? ""
        let folder = ModCatalog.root(game: game).appending(path: "packages/selftest.map/1.0.0", directoryHint: .isDirectory)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? """
        format_version = 1
        id = "selftest.map"
        version = "1.0.0"
        name = "Map"
        [[target]]
        game_id = "supermetroid-jpn"
        [[feature]]
        id = "pause"
        name = "Pause map"
        [[resource]]
        feature = "pause"
        id = "art"
        label = "Map art"
        shared_key = "selftest.art"
        normalized_sha256 = "\(hash)"
        file_patterns = "*.gba"
        [[feature]]
        id = "world"
        name = "World map"
        [[resource]]
        feature = "world"
        id = "art"
        label = "Map art (optional)"
        shared_key = "selftest.art"
        normalized_sha256 = "\(hash)"
        required = false
        """.write(to: folder.appending(path: "manifest.toml"), atomically: true, encoding: .utf8)
        let mods = ModsModel(game: game)
        guard let pause = mods.packages.first?.features.first(where: { $0.id == "pause" }),
              let world = mods.packages.first?.features.first(where: { $0.id == "world" }) else {
            return check("a feature's [[resource]] is read", false, "\(mods.packages)")
        }
        await mods.checkResource(pause.resources[0], in: pause)
        check("a required file not chosen blocks its feature", mods.isBlocked(pause) && !mods.isBlocked(world))
        mods.setPath(art.path, of: world.resources[0], in: world) { _ in }
        await mods.checkResource(pause.resources[0], in: pause)
        check("a shared file chosen for one feature counts for the other", mods.path(of: pause.resources[0], in: pause) == art.path
              && mods.status(of: pause.resources[0], in: pause) == .verified && !mods.isBlocked(pause),
              "\(String(describing: mods.status(of: pause.resources[0], in: pause))), hash \(hash.prefix(8))")
        mods.setEnabled(true, pause) { _ in }
        let state = (try? String(contentsOf: mods.root.appending(path: "state.toml"), encoding: .utf8)) ?? ""
        check("the file's path is saved where the game reads it", state.contains("[[shared_resource]]\nid = \"selftest.art\"\npath = \"\(art.path)\""), state)
        try? Data(repeating: 1, count: 32768).write(to: art)
        await mods.checkResource(pause.resources[0], in: pause)
        check("another file in its place is refused", mods.status(of: pause.resources[0], in: pause) == .wrongFile && mods.isBlocked(pause))
        mods.setPath("", of: pause.resources[0], in: pause) { _ in }
        check("clearing a required file turns its feature off", !mods.state.isEnabled(pause))
    }

    /// Every file under a folder, as paths relative to it.
    private static func files(in folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { !$0.hasSuffix("/") }.sorted()
    }

    /// Every file next to the test database, to show the ROM wasn't copied there.
    private static func dataFiles() -> [String] {
        let folder = Store.url.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("SMLauncherPlus") && !$0.hasSuffix(".log") && !$0.hasPrefix("SMLauncherPlus-shots") }.sorted()
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
