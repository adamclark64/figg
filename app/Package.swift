// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "figg",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Figg", targets: ["Figg"]),
        .executable(name: "figg-audio-probe", targets: ["figg-audio-probe"]),
        .executable(name: "figg-asr-bench", targets: ["figg-asr-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.0"),
    ],
    targets: [
        .target(
            name: "FiggStore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "FiggAudio"),
        .target(name: "FiggMeetingApps"),
        .target(name: "FiggConfig", dependencies: [.product(name: "Yams", package: "Yams")]),
        .target(
            name: "FiggTranscription",
            dependencies: [
                "FiggStore", "FiggAudio", "FiggMeetingApps",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(name: "FiggCalendar"),
        .target(name: "FiggWidget"),
        .target(name: "FiggLLM"),
        .target(name: "FiggNotes", dependencies: ["FiggStore", "FiggLLM"]),
        .target(name: "FiggExport", dependencies: ["FiggStore", "FiggNotes"]),
        .target(name: "FiggFeedback", dependencies: ["FiggExport"]),
        .target(name: "FiggUpdate", dependencies: ["FiggExport"]),
        .executableTarget(
            name: "Figg",
            dependencies: [
                "FiggStore", "FiggAudio", "FiggTranscription",
                "FiggLLM", "FiggNotes", "FiggExport", "FiggConfig", "FiggCalendar", "FiggUpdate", "FiggFeedback",
                "FiggWidget", "FiggMeetingApps",
            ]
        ),
        .executableTarget(name: "figg-audio-probe", dependencies: ["FiggAudio"]),
        .executableTarget(name: "figg-asr-bench", dependencies: ["FiggTranscription", "FiggStore", "FiggAudio"]),
        .testTarget(name: "FiggMeetingAppsTests", dependencies: ["FiggMeetingApps"]),
        .testTarget(name: "FiggStoreTests", dependencies: ["FiggStore"]),
        .testTarget(name: "FiggLLMTests", dependencies: ["FiggLLM"]),
        .testTarget(name: "FiggConfigTests", dependencies: ["FiggConfig"]),
        .testTarget(name: "FiggCalendarTests", dependencies: ["FiggCalendar"]),
        .testTarget(name: "FiggWidgetTests", dependencies: ["FiggWidget"]),
        .testTarget(name: "FiggNotesTests", dependencies: ["FiggNotes", "FiggStore", "FiggLLM"]),
        .testTarget(name: "FiggExportTests", dependencies: ["FiggExport", "FiggNotes"]),
        .testTarget(name: "FiggFeedbackTests", dependencies: ["FiggFeedback", "FiggExport"]),
        .testTarget(name: "FiggUpdateTests", dependencies: ["FiggUpdate", "FiggExport"]),
        .testTarget(
            name: "FiggTranscriptionTests",
            dependencies: ["FiggTranscription", "FiggStore", "FiggAudio", "FiggMeetingApps", .product(name: "FluidAudio", package: "FluidAudio")],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
