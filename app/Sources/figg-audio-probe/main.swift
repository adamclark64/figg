import FiggAudio
import FiggMeetingApps
import Foundation

// Dev tool: records a few seconds with figg's Recorder and reports what
// started, what failed, and how loud each stream was.
// Usage: swift run figg-audio-probe [seconds]
//        swift run figg-audio-probe --mic-users   (which apps hold the mic now)
//        swift run figg-audio-probe --ax-dump <zoom|...> [--replace "Real Name=Person A"]... [--keep-values]
//          (saves what figg reads of a meeting app to /tmp/figg-ax-<id>.json, scrubbed, for test fixtures)
// Note: when run from a terminal, macOS applies the terminal's permissions, not
// figg's. To test figg's own permissions: open build/Figg.app --args --probe-audio
setvbuf(stdout, nil, _IONBF, 0)
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 6
if let dump = AXDump.arguments(CommandLine.arguments) {
    print(AXDump.run(profileID: dump.id, replacements: dump.replacements, keepValues: dump.keepValues))
    exit(0)
}
if !CommandLine.arguments.contains("--mic-users") {
    print(await AudioProbe.run(seconds: seconds))
}

if CommandLine.arguments.contains("--mic-users"), #available(macOS 14.2, *) {
    print("apps using a microphone now: \(MicUsage.appsUsingInput().sorted())")
}
