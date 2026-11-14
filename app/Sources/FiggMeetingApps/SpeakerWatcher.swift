import Foundation

/// Polls a meeting app twice a second for the length of one recording and
/// keeps a `SpeakerTimeline`, saved to disk every few seconds and on stop.
/// Runs on its own queue, so a slow or hung meeting app never holds up
/// recording or the UI; a missed reading is just a gap in the timeline.
public final class SpeakerWatcher: @unchecked Sendable {
    public let meetingId: String
    private let reader: MeetingAppReader
    private let clock: @Sendable () -> Double
    private let file: URL
    private let interval: Double
    private let queue = DispatchQueue(label: "figg.speaker-watcher", qos: .utility)
    private let lock = NSLock()
    private var timeline: SpeakerTimeline
    private var timer: DispatchSourceTimer?
    private var lastSave = 0.0

    /// - Parameters:
    ///   - clock: seconds since the recording started (`Recorder.elapsed`).
    ///   - file: where the timeline is saved, normally `<meeting>/speakers.json`.
    public init(meetingId: String, app: String, reader: MeetingAppReader, file: URL, interval: Double = 0.5, clock: @escaping @Sendable () -> Double) {
        self.meetingId = meetingId
        self.reader = reader
        self.file = file
        self.interval = interval
        self.clock = clock
        timeline = SpeakerTimeline.load(from: file) ?? SpeakerTimeline(app: app)
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    /// Stops polling and writes the timeline one last time.
    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { save() }
    }

    /// The timeline so far.
    public var current: SpeakerTimeline {
        lock.lock(); defer { lock.unlock() }
        return timeline
    }

    func poll() {
        let time = clock()
        let snapshot = reader.read()
        lock.lock()
        timeline.record(snapshot, at: time, interval: interval)
        lock.unlock()
        if time - lastSave >= 5 { save(); lastSave = time }
    }

    private func save() {
        let t = current
        guard !t.spans.isEmpty || !t.participants.isEmpty else { return }
        do { try t.save(to: file) } catch { NSLog("figg: could not save speaker names: \(error.localizedDescription)") }
    }
}

/// Holds the running recording's watcher where the transcription queue's
/// background task can ask it for live names.
public final class SpeakerWatcherSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var watcher: SpeakerWatcher?

    public init() {}

    public func set(_ watcher: SpeakerWatcher?) {
        lock.lock(); defer { lock.unlock() }
        self.watcher = watcher
    }

    /// The name shown for most of [start, end] in that meeting, if it is the one being watched.
    public func name(meetingId: String, start: Double, end: Double) -> String? {
        lock.lock()
        let w = watcher
        lock.unlock()
        guard let w, w.meetingId == meetingId else { return nil }
        return w.current.name(start: start, end: end)
    }
}
