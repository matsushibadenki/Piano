import Synchronization

enum PianoParameter: UInt32, CaseIterable {
    case reverb = 0
    case body = 1
    case hammer = 2
    case brightness = 3
    case decay = 4
    case unison = 5
    case inharmonicity = 6
    case resonance = 7
    case volume = 8

    var identifier: String {
        switch self {
        case .reverb: "roomReverb"
        case .body: "soundboardBody"
        default: String(describing: self)
        }
    }

    var defaultPercent: Int {
        switch self {
        case .reverb: 30
        case .body: 45
        case .resonance: 100
        default: 50
        }
    }

    var title: String {
        switch self {
        case .reverb: "Room reverb"
        case .body: "Soundboard body"
        case .hammer: "Hammer"
        case .brightness: "Brightness"
        case .decay: "Decay"
        case .unison: "Unison"
        case .inharmonicity: "Inharmonicity"
        case .resonance: "Resonance"
        case .volume: "Volume"
        }
    }

    var step: Double { self == .unison || self == .inharmonicity ? 50 : 1 }

    var storageKey: String { identifier + "Percent" }
}

/// Shared between control/host threads and one render callback.
final class PianoParameters: Sendable {
    private final class Value: Sendable {
        let percent: Atomic<Float>
        init(_ percent: Int) { self.percent = Atomic(Float(percent)) }
    }

    private let controls = PianoParameter.allCases
    private let values = PianoParameter.allCases.map { Value($0.defaultPercent) }

    func get(_ parameter: PianoParameter) -> Float {
        values[Int(parameter.rawValue)].percent.load(ordering: .relaxed)
    }

    func set(_ parameter: PianoParameter, _ percent: Float) {
        guard percent.isFinite else { return }
        let clamped = min(100, max(0, percent))
        let amount = parameter.step == 50 ? (clamped / 50).rounded() * 50 : clamped
        values[Int(parameter.rawValue)].percent.store(amount, ordering: .relaxed)
    }

    func apply(to model: PianoModel) {
        for parameter in controls {
            model.setParameter(parameter, percent: get(parameter))
        }
    }
}
