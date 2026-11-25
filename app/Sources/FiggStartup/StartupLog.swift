import Foundation

/// What one launch recorded: the last stage it reached and, if the main
/// thread stalled, the longest stall and the stage it happened at.
public struct StartupRecord: Equatable, Sendable {
    public var stage: StartupStage
    public var stall: Stall?

    /// A main-thread stall: where it happened and how long it lasted.
    public struct Stall: Equatable, Sendable {
        public var stage: StartupStage
        public var seconds: Int

        public init(stage: StartupStage, seconds: Int) {
            self.stage = stage
            self.seconds = seconds
        }
    }

    public init(stage: StartupStage, stall: Stall? = nil) {
        self.stage = stage
        self.stall = stall
    }

    /// One phrase for a report, e.g. `ready`, `stalled at window-drawn for
    /// 12 s`, or `ready after a stall at window-drawn for 4 s` when the
    /// launch got past the stall.
    public var phrase: String {
        guard let stall else { return stage.rawValue }
        if stall.stage == stage {
            return "stalled at \(stall.stage.rawValue) for \(stall.seconds) s"
        }
        return "\(stage.rawValue) after a stall at \(stall.stage.rawValue) for \(stall.seconds) s"
    }

    /// The file text. Only stage labels, two fixed keys and a number, so
    /// the file can never hold anything a report must not carry.
    var fileText: String {
        var lines = ["stage: \(stage.rawValue)"]
        if let stall { lines.append("stall: \(stall.stage.rawValue) \(stall.seconds)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads `fileText` back. Unknown labels and malformed lines are
    /// dropped, so a damaged or foreign file never reaches a report.
    init?(fileText: String) {
        var stage: StartupStage?
        var stall: Stall?
        for line in fileText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count == 2, parts[0] == "stage:", let s = StartupStage(rawValue: parts[1]) {
                stage = s
            } else if parts.count == 3, parts[0] == "stall:", let s = StartupStage(rawValue: parts[1]),
                      let n = Int(parts[2]), n >= 0 {
                stall = Stall(stage: s, seconds: n)
            }
        }
        guard let stage else { return nil }
        self.init(stage: stage, stall: stall)
    }
}

/// Records how far startup got in `startup-stage.txt` in figg's data
/// folder, so the next bug report can say where a launch stopped (issue
/// 151: a main window that never drew, with no clue which step hung).
///
/// The file is state, not a setting, like `last-signer.txt`. Every write
/// is best effort: a missing or unwritable folder makes the log do
/// nothing rather than fail startup. The stall watchdog writes from a
/// background queue while the main thread may be stuck, so all state sits
/// behind a lock instead of on the main actor.
public final class StartupLog: @unchecked Sendable {
    public static let fileName = "startup-stage.txt"

    /// The app's one log, in `~/Library/Application Support/figg`. Worked
    /// out with FileManager directly so it can be used before the store
    /// (or anything else) has been opened.
    public static let shared: StartupLog = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return StartupLog(folder: base.appendingPathComponent("figg", isDirectory: true))
    }()

    public let fileURL: URL
    private let folder: URL
    private let lock = NSLock()
    private var _current: StartupRecord?
    private var _previous: StartupRecord?

    public init(folder: URL) {
        self.folder = folder
        self.fileURL = folder.appendingPathComponent(Self.fileName)
    }

    /// This launch's record, nil before `begin()`.
    public var current: StartupRecord? { locked { _current } }

    /// The record the previous launch left in the file, read by `begin()`.
    public var previous: StartupRecord? { locked { _previous } }

    /// Starts this launch's record. The previous launch's record is kept in
    /// memory first, because the new record overwrites the file and the
    /// previous one is what a report after a failed launch needs.
    public func begin() {
        locked {
            _previous = (try? String(contentsOf: fileURL, encoding: .utf8)).flatMap(StartupRecord.init(fileText:))
            _current = StartupRecord(stage: .launched)
            write()
        }
    }

    /// Records that this launch reached `stage`. A stall seen earlier is
    /// kept, so a launch that recovered still says it stalled.
    public func reached(_ stage: StartupStage) {
        locked {
            var record = _current ?? StartupRecord(stage: stage)
            record.stage = stage
            _current = record
            write()
        }
    }

    /// Records that the main thread has not answered for `seconds` at
    /// `stage`. The watchdog calls this again as a stall grows; the
    /// longest stall of the launch is the one kept.
    public func stalled(at stage: StartupStage, seconds: TimeInterval) {
        let whole = seconds.isFinite ? max(0, Int(seconds)) : 0
        locked {
            var record = _current ?? StartupRecord(stage: stage)
            record.stage = stage
            if record.stall.map({ whole >= $0.seconds }) ?? true {
                record.stall = .init(stage: stage, seconds: whole)
            }
            _current = record
            write()
        }
    }

    /// One line for a bug report, e.g.
    /// `this launch: ready; last launch: stalled at window-drawn for 12 s`.
    public var summary: String {
        locked {
            let now = _current?.phrase ?? "not started"
            let last = _previous?.phrase ?? "none"
            return "this launch: \(now); last launch: \(last)"
        }
    }

    /// Writes the current record. Called with the lock held.
    private func write() {
        guard let record = _current else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(record.fileText.utf8).write(to: fileURL, options: .atomic)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
