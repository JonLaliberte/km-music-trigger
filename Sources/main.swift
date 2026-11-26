// km-music-trigger
//
// Listens for the playerInfo notification that Apple Music broadcasts
// (com.apple.Music.playerInfo) and runs a Keyboard Maestro macro when playback
// changes. It uses no CPU while idle: it sleeps until macOS delivers a
// notification, and nothing ever polls Music.

import Foundation

let version = "0.1.1"

// MARK: - Options

struct Options {
    var macro = ""
    var events: Set<String> = ["playing", "paused", "stopped"]
    var json = false
    var verbose = false
    var dryRun = false
}

let validEvents: Set<String> = ["playing", "paused", "stopped", "track"]

func usage() -> String {
    """
    km-music-trigger \(version)
    Run a Keyboard Maestro macro when Apple Music starts, pauses or stops playing.

    Usage: km-music-trigger --macro <name or UUID> [options]

      -m, --macro <name|UUID>  Macro to run (required). A UUID is safer than a name.
      -e, --on <list>          Comma-separated events that run the macro.
                               playing, paused, stopped, track
                               (default: playing,paused,stopped)
      -j, --json               Pass a JSON object as the parameter instead of the event name.
      -n, --dry-run            Print what would run, without calling Keyboard Maestro.
      -v, --verbose            Log every notification received, even ignored ones.
      -h, --help               Show this help.
          --version            Show the version.

    The macro receives the event as its parameter: %TriggerValue% is
    "playing", "paused", "stopped" or "track". With --json it is a JSON object, e.g.
    {"event":"playing","state":"Playing","name":"…","artist":"…","album":"…"}

    The settings can also come from the environment: KMMT_MACRO, KMMT_ON, KMMT_JSON=1.
    """
}

func parseOptions() -> Options {
    var o = Options()
    let env = ProcessInfo.processInfo.environment
    if let m = env["KMMT_MACRO"] { o.macro = m }
    if let e = env["KMMT_ON"] { o.events = parseEvents(e) }
    if env["KMMT_JSON"] == "1" { o.json = true }

    var args = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else { fail("\(flag) needs a value") }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "-m", "--macro": o.macro = value(a)
        case "-e", "--on": o.events = parseEvents(value(a))
        case "-j", "--json": o.json = true
        case "-n", "--dry-run": o.dryRun = true
        case "-v", "--verbose": o.verbose = true
        case "-h", "--help": print(usage()); exit(0)
        case "--version": print(version); exit(0)
        default: fail("unknown option \(a)\n\n\(usage())")
        }
    }
    if o.macro.isEmpty { fail("--macro is required\n\n\(usage())") }
    return o
}

func parseEvents(_ s: String) -> Set<String> {
    let set = Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    let bad = set.subtracting(validEvents)
    if !bad.isEmpty { fail("unknown event(s): \(bad.sorted().joined(separator: ", ")). Valid: \(validEvents.sorted().joined(separator: ", "))") }
    return set
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("km-music-trigger: \(msg)\n".utf8))
    exit(64)
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(msg)")
    trimLogIfNeeded()
}

// When stdout is a file (as under launchd), keep it small: once it passes
// logMaxBytes, cut it down to the most recent logKeepBytes. launchd opens the log
// in append mode, so later writes continue at the new end of the file.
let logMaxBytes: Int64 = 100_000
let logKeepBytes: Int64 = 50_000

func trimLogIfNeeded() {
    fflush(stdout)
    var st = stat()
    guard fstat(STDOUT_FILENO, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > logMaxBytes else { return }
    var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(STDOUT_FILENO, F_GETPATH, &pathBuf) != -1,
          let file = FileHandle(forUpdatingAtPath: String(cString: pathBuf)) else { return }
    defer { try? file.close() }
    do {
        try file.seek(toOffset: UInt64(st.st_size - logKeepBytes))
        var tail = try file.readToEnd() ?? Data()
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail.suffix(from: tail.index(after: nl)) }  // start on a whole line
        try file.truncate(atOffset: 0)
        let note = "\(ISO8601DateFormatter().string(from: Date())) (log trimmed to the last \(logKeepBytes / 1000) KB)\n"
        try file.write(contentsOf: Data(note.utf8) + tail)
    } catch {
        // Logging must never stop the listener.
    }
}

// MARK: - Keyboard Maestro

func appleScriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func runMacro(_ macro: String, parameter: String, dryRun: Bool) {
    let source = "tell application \"Keyboard Maestro Engine\" to do script \(appleScriptString(macro)) with parameter \(appleScriptString(parameter))"
    if dryRun {
        log("dry run: \(source)")
        return
    }
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
        log("error running macro: \(error[NSAppleScript.errorMessage] ?? error)")
    }
}

// MARK: - Listener

setvbuf(stdout, nil, _IOLBF, 0)
let options = parseOptions()

var lastState: String? = nil
var lastTrack: String? = nil

func handle(_ info: [AnyHashable: Any]) {
    let state = info["Player State"] as? String ?? "Unknown"   // Playing, Paused, Stopped
    let name = info["Name"] as? String ?? ""
    let artist = info["Artist"] as? String ?? ""
    let album = info["Album"] as? String ?? ""
    let track = [name, artist, album].joined(separator: "\u{1F}")

    // Music often posts the same state more than once per change (on pause it sends
    // "Playing" and then "Paused"), so act only when something actually changes.
    var event: String? = nil
    if state != lastState {
        event = state.lowercased()
    } else if state == "Playing", track != lastTrack {
        event = "track"
    }
    lastState = state
    lastTrack = track

    guard let event else {
        if options.verbose { log("ignored repeat: \(state) \(name)") }
        return
    }
    guard options.events.contains(event) else {
        if options.verbose { log("not configured: \(event) \(name)") }
        return
    }

    let parameter: String
    if options.json {
        let obj: [String: String] = ["event": event, "state": state, "name": name, "artist": artist, "album": album]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        parameter = String(data: data, encoding: .utf8) ?? event
    } else {
        parameter = event
    }

    log("\(event): \(name)\(artist.isEmpty ? "" : " — \(artist)") → \(options.macro)")
    runMacro(options.macro, parameter: parameter, dryRun: options.dryRun)
}

// Music posts a burst of notifications for each change, and on a pause the first
// one still says "Playing". Wait briefly and act only on the last one in the burst.
var pending: DispatchWorkItem? = nil
let settleDelay = 0.25

// Music also posts the same data as com.apple.iTunes.playerInfo; listening to
// both would run the macro twice.
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
) { note in
    let info = note.userInfo ?? [:]
    if options.verbose { log("received: \(info["Player State"] ?? "?") \(info["Name"] ?? "")") }
    pending?.cancel()
    let work = DispatchWorkItem { handle(info) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
}

log("km-music-trigger \(version) listening; macro=\(options.macro) on=\(options.events.sorted().joined(separator: ","))\(options.json ? " json" : "")\(options.dryRun ? " dry-run" : "")")
RunLoop.main.run()
