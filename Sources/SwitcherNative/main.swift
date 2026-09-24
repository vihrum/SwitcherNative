import AppKit

let logPath = ("~/Library/Logs/SwitcherNative.log" as NSString).expandingTildeInPath
freopen(logPath.cString(using: .utf8), "a+", stdout)
freopen(logPath.cString(using: .utf8), "a+", stderr)
setbuf(stdout, nil)

print("\n--- SwitcherNative started at \(Date()) ---")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
