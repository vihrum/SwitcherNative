import AppKit

let logPath = ("~/Library/Logs/SwitcherNative.log" as NSString).expandingTildeInPath

// Rotate log if it exceeds 2 MB to prevent disk exhaustion
if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
   let size = attrs[.size] as? Int64, size > 2 * 1024 * 1024 {
    let oldLogPath = ("~/Library/Logs/SwitcherNative.old.log" as NSString).expandingTildeInPath
    _ = try? FileManager.default.removeItem(atPath: oldLogPath)
    _ = try? FileManager.default.moveItem(atPath: logPath, toPath: oldLogPath)
}

freopen(logPath.cString(using: .utf8), "a+", stdout)
freopen(logPath.cString(using: .utf8), "a+", stderr)
setbuf(stdout, nil)

print("\n--- SwitcherNative started at \(Date()) ---")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
