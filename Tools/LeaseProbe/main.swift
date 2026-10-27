import Foundation
import KeepOnlineCore
import KeepOnlinePlatform

/// Internal integration fixture, never embedded in the app bundle.
let backend = IOKitPowerBackend()
let kind: PowerKind = CommandLine.arguments.contains("--disk") ? .diskIdle : .systemIdle
func emit(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
do {
    let token = try backend.create(kind: kind, timeout: 4)
    defer { try? backend.release(token) }
    emit("READY \(ProcessInfo.processInfo.processIdentifier) \(token.rawValue)")
    while let command = readLine() {
        do {
            switch command {
            case "inspect": emit(try backend.inspect(token) ? "ACTIVE" : "ABSENT")
            case "renew": try backend.renew(token, timeout: 4); emit("RENEWED")
            case "stop": try backend.release(token); emit("STOPPED"); exit(0)
            default: emit("UNKNOWN")
            }
        } catch { emit("ERROR \(error)") }
    }
} catch {
    emit("FAILED \(error)")
    exit(1)
}
