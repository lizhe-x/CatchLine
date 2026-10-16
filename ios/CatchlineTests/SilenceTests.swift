import Foundation
import Testing
@testable import Catchline

struct SilenceTests {
    private func chunk(amplitude: Double) -> Data {
        // 100 ms of a 440 Hz sine at 16 kHz.
        var samples = (0..<1600).map { Int16(amplitude * 32767 * sin(2 * .pi * 440 * Double($0) / 16_000)) }
        return Data(bytes: &samples, count: samples.count * 2)
    }

    @Test func silenceIsZero() {
        #expect(Captioner.rms(Data(count: 3200)) == 0)
        #expect(Captioner.rms(Data()) == 0)
    }

    @Test func sineRMSIsAmplitudeOverRootTwo() {
        #expect(abs(Captioner.rms(chunk(amplitude: 0.5)) - 0.5 / 2.squareRoot()) < 0.001)
    }

    @Test func quietVoiceCountsAsSound() {
        // About -40 dBFS: a soft voice or a phone on speaker across the table.
        #expect(Captioner.rms(chunk(amplitude: 0.014)) > Captioner.soundRMS)
        // About -55 dBFS: a quiet room.
        #expect(Captioner.rms(chunk(amplitude: 0.0025)) < Captioner.soundRMS)
    }
}
