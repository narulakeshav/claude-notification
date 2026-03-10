import Cocoa
import UserNotifications

// ── Config ──────────────────────────────────────────────────────────────
// Reads ~/.claude-notify.json for terminal bundle ID

struct Config: Decodable {
    let terminalBundleId: String?
}

func loadConfig() -> Config? {
    let path = NSString("~/.claude-notify.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

let config = loadConfig()

// ── Notification Delegate ───────────────────────────────────────────────

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let bundleId = config?.terminalBundleId,
           let terminal = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundleId
           }) {
            terminal.activate()
        }
        completionHandler()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// ── Parse hook input from stdin ─────────────────────────────────────────

struct HookInput: Decodable {
    let message: String?
    let title: String?
    let notification_type: String?
    let cwd: String?
}

func readStdin() -> HookInput? {
    let fd = FileHandle.standardInput.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let data = FileHandle.standardInput.availableData
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(HookInput.self, from: data)
}

let hookInput = readStdin()

// ── Build notification content ──────────────────────────────────────────

let project: String = {
    if let cwd = hookInput?.cwd {
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
    if CommandLine.arguments.count > 2 {
        return CommandLine.arguments[2]
    }
    return ""
}()

let body: String = {
    if let type = hookInput?.notification_type {
        switch type {
        case "permission_prompt":
            return hookInput?.message ?? "Needs your permission"
        case "idle_prompt":
            return "Waiting for your input"
        case "stop":
            return "Finished working"
        default:
            return hookInput?.message ?? "Needs your attention"
        }
    }
    if CommandLine.arguments.count > 3 {
        return CommandLine.arguments[3]
    }
    return "Needs your attention"
}()

let title: String = {
    let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Claude Code"
    return project.isEmpty ? base : "\(base) · \(project)"
}()

// ── Send notification ───────────────────────────────────────────────────
// Only send if we have actual input (stdin or CLI args).
// When macOS relaunches the app to handle a notification click,
// there's no input — so we skip sending to avoid an infinite loop.

let hasInput = hookInput != nil || CommandLine.arguments.count > 1

let app = NSApplication.shared
let delegate = NotificationDelegate()

let center = UNUserNotificationCenter.current()
center.delegate = delegate

let semaphore = DispatchSemaphore(value: 0)
center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
    semaphore.signal()
}
semaphore.wait()

if hasInput {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(request) { error in
        if let error = error {
            fputs("Error: \(error.localizedDescription)\n", stderr)
        }
    }

    // Stay alive for 30s to handle notification clicks (focus terminal)
    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
        NSApplication.shared.terminate(nil)
    }
    app.run()
} else {
    exit(0)
}
