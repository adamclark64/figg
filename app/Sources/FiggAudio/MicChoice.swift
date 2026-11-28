import Foundation

/// An audio input as far as choosing the mic is concerned.
public struct InputDevice: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case builtIn, bluetooth, other
    }

    public var id: UInt32
    public var name: String
    public var transport: Transport

    public init(id: UInt32, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }
}

/// Which mic records "Me".
///
/// macOS makes a Bluetooth headset (AirPods and the like) the default input
/// as soon as it connects, and recording from it switches the headset into
/// its call mode: narrowband, low-quality audio, and worse music for the
/// wearer. With headphones on, the Mac's own mic hears only the user (the
/// call plays in their ears), so it is the better source. Anything else
/// (a USB or wired mic the user picked) is left alone.
public enum MicChoice {
    /// The device to record from instead of the system default, or nil to
    /// keep the default.
    public static func override(preferBuiltIn: Bool, defaultInput: InputDevice?, inputs: [InputDevice],
                                lidClosed: Bool) -> InputDevice? {
        guard preferBuiltIn, !lidClosed, defaultInput?.transport == .bluetooth else { return nil }
        return inputs.first { $0.transport == .builtIn }
    }
}
