import Foundation

/// The only automatic context a report may carry (privacy: never audio,
/// transcripts, notes, meeting titles, calendar data or logs). The app layer
/// adds its bundle version, build and active transcriber engine.
public enum ReportContext {
    /// e.g. "macOS 26.1 (Build 25B123)".
    public static var macOSVersion: String {
        "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
    }

    /// e.g. "Mac16,8". Empty when sysctl fails.
    public static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
