// swift-tools-version:6.0
import PackageDescription

// A COMMAND-LINE CALL, NOT AN APP.
//
// The app comes later. What has to be proved first is the floor: how much
// latency the PIPELINE adds when the network adds none. Everything about a UI
// makes that harder to see, so there is no UI here -- two processes, one clock,
// and a number printed once a second.
let package = Package(
  name: "tk",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "tk",
      path: "Sources/tk",
      // Swift 5 language mode, deliberately. Swift 6 actor isolation cannot model
      // what this program does on purpose: a real-time CoreAudio render callback
      // reading a lock-free ring written by a socket thread, with no locks
      // anywhere because a lock on the audio thread is a dropout. The checker's
      // only available advice there is to add synchronisation that would break
      // the thing it is protecting.
      swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"])],
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AVFoundation"),
        // The system recogniser, used when there is no local Qwen daemon --
        // which is every machine but the one this was built on. Weak by
        // availability rather than by link: the whole file is behind
        // `#available(macOS 26.0, *)` and the package floor is 14.
        .linkedFramework("Speech"),
      ]
    ),
    // A separate binary on purpose: it opens the microphone and a window, and it
    // must never be linkable into a call. Its own bundle id gives it its own
    // microphone grant, so testing it cannot disturb Kin's.
    .executableTarget(
      name: "voicelab",
      path: "Sources/voicelab",
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("AVFoundation"),
      ]
    )
  ]
)
