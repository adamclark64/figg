import FiggAudio
import Testing

@Suite struct MicChoiceTests {
    let macMic = InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)
    let airPods = InputDevice(id: 2, name: "AirPods Pro", transport: .bluetooth)
    let usbMic = InputDevice(id: 3, name: "USB Mic", transport: .other)

    @Test func bluetoothDefaultSwitchesToTheMacsMic() {
        let chosen = MicChoice.override(preferBuiltIn: true, defaultInput: airPods,
                                        inputs: [airPods, macMic, usbMic], lidClosed: false)
        #expect(chosen == macMic)
    }

    @Test func otherDefaultsAreLeftAlone() {
        for input in [macMic, usbMic] {
            #expect(MicChoice.override(preferBuiltIn: true, defaultInput: input,
                                       inputs: [airPods, macMic, usbMic], lidClosed: false) == nil)
        }
        #expect(MicChoice.override(preferBuiltIn: true, defaultInput: nil, inputs: [macMic], lidClosed: false) == nil)
    }

    @Test func turnedOffKeepsTheHeadset() {
        #expect(MicChoice.override(preferBuiltIn: false, defaultInput: airPods,
                                   inputs: [airPods, macMic], lidClosed: false) == nil)
    }

    @Test func closedLidOrNoBuiltInMicKeepsTheHeadset() {
        // A shut MacBook's mic is cut off in hardware: it would record silence.
        #expect(MicChoice.override(preferBuiltIn: true, defaultInput: airPods,
                                   inputs: [airPods, macMic], lidClosed: true) == nil)
        // A Mac mini or Mac Pro has no mic of its own.
        #expect(MicChoice.override(preferBuiltIn: true, defaultInput: airPods,
                                   inputs: [airPods, usbMic], lidClosed: false) == nil)
    }
}
