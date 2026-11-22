/// Owns one instance of the original F1 DSP. Events and rendering run on
/// the same Core Audio callback, after construction on the audio worker.
final class PianoModel {
    private let handle: OpaquePointer

    init(sampleRate: Double) {
        handle = piano_f1_create(sampleRate)
    }

    deinit {
        piano_f1_destroy(handle)
    }

    func noteOn(_ note: Int, velocity: Float, soft: Bool = false) {
        piano_f1_note_on(handle, UInt32(note), velocity, soft)
    }

    func noteOff(_ note: Int) {
        piano_f1_note_off(handle, UInt32(note))
    }

    func sustain(_ value: Float) {
        piano_f1_sustain(handle, value)
    }

    func releaseAll() {
        piano_f1_all_off(handle)
    }

    func setParameter(_ parameter: PianoParameter, percent: Float) {
        piano_f1_set_parameter(handle, parameter.rawValue, percent / 100)
    }

    func render(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: UInt32) {
        piano_f1_render(handle, left, right, frames)
    }
}
