import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// Reads and asks for figg's permissions through macOS.
///
/// System Audio Recording has no public API to check or ask, so it goes
/// through TCC's own `TCCAccessPreflight` / `TCCAccessRequest`, looked up at
/// run time. The same calls tell "never asked" from "refused" for
/// Accessibility and Screen Recording, whose public checks only say yes or no.
/// If TCC's symbols are ever missing, those rows fall back to the public
/// checks and the Fix step still works.
public enum SystemPermissions {
    public static func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .systemAudio:
            return TCC.preflight("kTCCServiceAudioCapture") ?? .denied
        case .accessibility:
            if AXIsProcessTrusted() { return .granted }
            return notGranted(TCC.preflight("kTCCServiceAccessibility"))
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return notGranted(TCC.preflight("kTCCServiceScreenCapture"))
        }
    }

    /// The public check said no; TCC can still say whether it was asked.
    private static func notGranted(_ tcc: PermissionStatus?) -> PermissionStatus {
        tcc == .notAsked ? .notAsked : .denied
    }

    /// Shows macOS's prompt where there is one. Returns once it is answered
    /// (or at once, for prompts that only open System Settings).
    @MainActor
    public static func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio:
            if !(await TCC.request("kTCCServiceAudioCapture")) { open(permission) }
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Clears figg's own entry for one permission so macOS asks afresh.
    /// Returns false if `tccutil` refused; nothing else is changed then.
    public static func reset(_ permission: Permission, bundleID: String) async -> Bool {
        let command = PermissionReset(permission, bundleID: bundleID)
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    @MainActor
    public static func open(_ permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }
}

/// TCC's private entry points, looked up once.
private enum TCC {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFn: Preflight? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: Preflight.self)
    }()

    private static let requestFn: Request? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: Request.self)
    }()

    /// 0 allowed, 1 refused, anything else never decided.
    static func preflight(_ service: String) -> PermissionStatus? {
        guard let preflightFn else { return nil }
        switch preflightFn(service as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notAsked
        }
    }

    /// Returns false when the request could not be made.
    static func request(_ service: String) async -> Bool {
        guard let requestFn else { return false }
        return await withCheckedContinuation { done in
            requestFn(service as CFString, nil) { _ in done.resume(returning: true) }
        }
    }
}
