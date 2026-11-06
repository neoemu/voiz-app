import AppKit
import Foundation

// Process lifecycle only: never targets com.rmb.voiz or forces a quit.
let bundleID = "com.rmb.voiz.dev"
let action = CommandLine.arguments.dropFirst().first ?? "status"
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
switch action {
case "status":
    let rows: [[String: Any]] = applications.map { app in
        ["pid": Int(app.processIdentifier), "path": app.bundleURL?.path ?? "unknown"]
    }
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "stop":
    for app in applications { _ = app.terminate() }
    let deadline = Date().addingTimeInterval(8)
    while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if applications.contains(where: { !$0.isTerminated }) {
        fputs("Voiz Dev continua aberto. Conclua gravação/processamento ou responda ao aviso no app. Nenhum encerramento foi forçado.\n", stderr)
        exit(1)
    }
    print(applications.isEmpty ? "Voiz Dev já estava fechado." : "Voiz Dev encerrado normalmente.")
default:
    fputs("Ação inválida. Use status ou stop.\n", stderr)
    exit(2)
}
