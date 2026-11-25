import Foundation
import Testing
@testable import FiggStartup

struct StartupLogTests {
    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func stagesRoundTripThroughTheFile() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = StartupLog(folder: dir)
        first.begin()
        first.reached(.storeOpened)
        first.reached(.windowDrawn)
        #expect(first.current == StartupRecord(stage: .windowDrawn))

        let next = StartupLog(folder: dir)
        next.begin()
        #expect(next.previous == StartupRecord(stage: .windowDrawn))
        #expect(next.current == StartupRecord(stage: .launched))
    }

    @Test func everyStageRoundTrips() {
        for stage in StartupStage.allCases {
            let record = StartupRecord(stage: stage, stall: .init(stage: stage, seconds: 7))
            #expect(StartupRecord(fileText: record.fileText) == record)
        }
    }

    @Test func previousLaunchStallShowsInSummary() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = StartupLog(folder: dir)
        first.begin()
        first.reached(.windowDrawn)
        first.stalled(at: .windowDrawn, seconds: 4.2)
        first.stalled(at: .windowDrawn, seconds: 12.9)

        let next = StartupLog(folder: dir)
        next.begin()
        next.reached(.ready)
        #expect(next.summary == "this launch: ready; last launch: stalled at window-drawn for 12 s")
    }

    @Test func recoveredStallIsKept() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = StartupLog(folder: dir)
        log.begin()
        log.stalled(at: .storeOpened, seconds: 5)
        log.stalled(at: .windowDrawn, seconds: 3.5)
        log.reached(.ready)
        #expect(log.current?.phrase == "ready after a stall at store-opened for 5 s")
    }

    @Test func summaryBeforeAnyLaunch() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = StartupLog(folder: dir)
        #expect(log.summary == "this launch: not started; last launch: none")
        log.begin()
        #expect(log.summary == "this launch: launched; last launch: none")
    }

    /// The file holds only stage labels, the two keys and whole seconds,
    /// and a foreign file is dropped rather than carried into a report.
    @Test func fileOnlyEverContainsKnownLabels() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(StartupLog.fileName)
        try "stage: some meeting title\nstall: secret 3\n".write(to: url, atomically: true, encoding: .utf8)

        let log = StartupLog(folder: dir)
        log.begin()
        #expect(log.previous == nil)
        #expect(log.summary == "this launch: launched; last launch: none")
        log.reached(.meetingsLoaded)
        log.stalled(at: .windowDrawn, seconds: 9)
        log.reached(.ready)

        let labels = Set(StartupStage.allCases.map(\.rawValue))
        let text = try String(contentsOf: url, encoding: .utf8)
        for token in text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init) {
            #expect(token == "stage:" || token == "stall:" || labels.contains(token) || Int(token) != nil, "unexpected \(token)")
        }
    }

    /// A folder that cannot be created (its parent is a file) leaves the log
    /// working in memory and never throws into startup.
    @Test func unwritableFolderDoesNotThrow() throws {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)

        let log = StartupLog(folder: file.appendingPathComponent("figg"))
        log.begin()
        log.reached(.windowDrawn)
        log.stalled(at: .windowDrawn, seconds: 6)
        #expect(log.previous == nil)
        #expect(log.summary == "this launch: stalled at window-drawn for 6 s; last launch: none")
        #expect(!FileManager.default.fileExists(atPath: log.fileURL.path))
    }

    @Test func sharedLogLivesInTheFiggDataFolder() {
        let url = StartupLog.shared.fileURL
        #expect(url.lastPathComponent == "startup-stage.txt")
        #expect(url.deletingLastPathComponent().lastPathComponent == "figg")
        #expect(url.path.contains("Application Support"))
    }

    @Test func stageLabelsAreFixed() {
        #expect(StartupStage.allCases.map(\.rawValue) == [
            "launched", "store-opened", "meetings-loaded", "window-drawn",
            "permissions-read", "services-started", "ready",
        ])
    }
}
