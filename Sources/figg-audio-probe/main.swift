import FiggAudio
import Foundation

// Dev tool: records a few seconds with figg's Recorder and reports what
// started, what failed, and how loud each stream was.
// Usage: swift run figg-audio-probe [seconds]
//        swift run figg-audio-probe --mic-users   (which apps hold the mic now)
// Note: run from a terminal, macOS applies the terminal's permissions, not
// figg's. To test figg's own permissions: open build/Figg.app --args --probe-audio
setvbuf(stdout, nil, _IONBF, 0)
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 6
if !CommandLine.arguments.contains("--mic-users") {
    print(await AudioProbe.run(seconds: seconds))
}

if CommandLine.arguments.contains("--mic-users"), #available(macOS 14.2, *) {
    print("apps using a microphone now: \(MicUsage.appsUsingInput().sorted())")
}
