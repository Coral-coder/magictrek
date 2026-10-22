import AVFoundation
import SwiftUI
import UIKit

/// Haptics and the little LCARS console beeps, synthesised at launch so no audio files are needed.
@MainActor
final class Feedback {
    static let shared = Feedback()
    var soundOn = true
    var hapticsOn = true

    enum Sound: CaseIterable { case tap, confirm, deny, draw, attack, damage, alert, victory, defeat, chirp }

    private var players: [Sound: AVAudioPlayer] = [:]
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for s in Sound.allCases {
            if let data = Feedback.wave(for: s), let p = try? AVAudioPlayer(data: data) { p.prepareToPlay(); p.volume = 0.5; players[s] = p }
        }
    }

    func play(_ s: Sound) {
        if soundOn, let p = players[s] { p.currentTime = 0; p.play() }
        guard hapticsOn else { return }
        switch s {
        case .tap, .draw, .chirp: impact.impactOccurred()
        case .attack, .damage: heavy.impactOccurred()
        case .confirm, .victory: notify.notificationOccurred(.success)
        case .deny, .defeat: notify.notificationOccurred(.error)
        case .alert: notify.notificationOccurred(.warning)
        }
    }

    /// A short tone sequence as 16-bit mono WAV.
    private static func wave(for s: Sound) -> Data? {
        let rate = 22_050.0
        let notes: [(Double, Double)]   // (frequency, seconds)
        switch s {
        case .tap: notes = [(1400, 0.03)]
        case .chirp: notes = [(1800, 0.03), (2400, 0.04)]
        case .confirm: notes = [(900, 0.05), (1300, 0.07)]
        case .deny: notes = [(400, 0.08), (300, 0.1)]
        case .draw: notes = [(1100, 0.03), (1500, 0.03)]
        case .attack: notes = [(600, 0.05), (900, 0.05), (1200, 0.08)]
        case .damage: notes = [(200, 0.12)]
        case .alert: notes = [(880, 0.12), (660, 0.12), (880, 0.12)]
        case .victory: notes = [(660, 0.1), (880, 0.1), (1100, 0.1), (1320, 0.25)]
        case .defeat: notes = [(500, 0.15), (400, 0.15), (300, 0.3)]
        }
        var samples: [Int16] = []
        for (f, d) in notes {
            let n = Int(rate * d)
            for i in 0..<n {
                let t = Double(i) / rate
                let env = min(1, Double(i) / 200) * min(1, Double(n - i) / 400)
                samples.append(Int16(sin(2 * .pi * f * t) * 12_000 * env))
            }
        }
        var data = Data()
        func put32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!); put32(36 + byteCount); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        data.append("data".data(using: .ascii)!); put32(byteCount)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
