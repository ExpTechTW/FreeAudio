import Foundation
import Testing
@testable import FreeAudio

@Suite struct ExposureTests {
    @Test func dailyDoseFollowsNIOSH() {
        #expect(abs(Exposure.dailyDose(level: 85, seconds: 8 * 3_600) - 100) < 1e-9)
        #expect(abs(Exposure.dailyDose(level: 88, seconds: 4 * 3_600) - 100) < 1e-9)
        #expect(abs(Exposure.dailyDose(level: 100, seconds: 15 * 60) - 100) < 1e-9)
        #expect(Exposure.dailyDose(level: 79.9, seconds: 3_600) == 0)
    }

    @Test func weeklyDoseFollowsWHO() {
        let energy = 40 * 3_600 * pow(10, 8.0)
        #expect(abs(Exposure.weeklyDose(energy: energy) - 100) < 1e-9)
    }

    @Test func levelAddsVolumeReferenceAndCalibration() {
        // A full-scale sine (-3 dB) at full volume on headphones, calibrated 2 dB down.
        #expect(abs(Exposure.level(meanSquare: 0.5, volumeDecibels: 0, kind: .headphones, calibration: -2) - 104.99) < 0.01)
        #expect(abs(Exposure.level(meanSquare: 0.001, volumeDecibels: -20, kind: .builtInSpeakers, calibration: 0) - 40) < 1e-9)
    }

    @Test func aDayAddsUp() {
        var day = HearingTally()
        day.add(level: 80.4, seconds: 60)
        day.add(level: 90.2, seconds: 60)
        #expect(day.monitored == 120 && day.peak == 90.2)
        #expect(day.seconds(from: 85) == 60 && day.seconds(from: 80, below: 85) == 60 && day.seconds(from: 91) == 0)
        let average = 10 * log10((pow(10, 8.04) + pow(10, 9.02)) / 2)
        #expect(abs((day.average ?? 0) - average) < 1e-9)
        #expect(abs(day.dose - (Exposure.dailyDose(level: 80.4, seconds: 60) + Exposure.dailyDose(level: 90.2, seconds: 60))) < 1e-12)
    }

    @MainActor @Test func recordsOnlyWhatIsHeard() {
        let monitor = HearingMonitor(store: nil)
        let headphones = AudioDevice(id: 1, uid: "hp", name: "Headphones", symbol: "headphones", kind: .headphones)
        let now = Date()
        monitor.record(meanSquare: 0.5, seconds: 1, device: headphones, volume: 0.5, volumeDecibels: -30, muted: false, at: now)
        #expect(monitor.day(now).monitored == 0 && monitor.live == nil)

        monitor.update {
            $0.monitoring = true
            $0.alerts = false
            $0.calibration["hp"] = 1
        }
        monitor.record(meanSquare: 0.5, seconds: 1, device: headphones, volume: 0.5, volumeDecibels: -30, muted: false, at: now)
        #expect(abs((monitor.live?.level ?? 0) - 77.99) < 0.01 && monitor.day(now).monitored == 1)
        // Silence and a muted device aren't exposure.
        monitor.record(meanSquare: 1e-9, seconds: 1, device: headphones, volume: 0.5, volumeDecibels: -30, muted: false, at: now)
        #expect(monitor.live?.level == nil && monitor.day(now).monitored == 1)
        monitor.record(meanSquare: 0.5, seconds: 1, device: headphones, volume: 0.5, volumeDecibels: -30, muted: true, at: now)
        #expect(monitor.day(now).monitored == 1)
        #expect(monitor.csv().split(separator: "\n").count == 2)
    }
}
