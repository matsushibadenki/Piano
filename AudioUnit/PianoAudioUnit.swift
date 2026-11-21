import AVFoundation
import AudioToolbox
import CoreMIDI
import Synchronization

@objc(PianoAUFactory)
final class PianoAUFactory: NSObject, AUAudioUnitFactory {
    func beginRequest(with context: NSExtensionContext) {}

    func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit {
        try PianoAudioUnit(componentDescription: description, options: [])
    }
}

final class PianoAudioUnit: AUAudioUnit {
    private let output: AUAudioUnitBus
    private var outputs: AUAudioUnitBusArray!
    private var inputs: AUAudioUnitBusArray!
    private var renderer: InstrumentRender?
    private let reverbPercent = Atomic<Float>(30)
    private let bodyPercent = Atomic<Float>(45)

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        output = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        output.maximumChannelCount = 2
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])

        let bundle = Bundle(for: PianoAUFactory.self)
        func percentParameter(_ identifier: String, label: String,
                              address: AUParameterAddress, initial: AUValue) -> AUParameter {
            let parameter = AUParameterTree.createParameter(
                withIdentifier: identifier, name: NSLocalizedString(label, bundle: bundle, comment: ""),
                address: address, min: 0, max: 100, unit: .percent, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil
            )
            parameter.value = initial
            return parameter
        }
        let tree = AUParameterTree.createTree(withChildren: [
            percentParameter("roomReverb", label: "Room reverb", address: 0, initial: 30),
            percentParameter("soundboardBody", label: "Soundboard body", address: 1, initial: 45),
        ])
        tree.implementorValueObserver = { [weak self] parameter, value in
            self?.setParameter(parameter.address, value)
        }
        tree.implementorValueProvider = { [weak self] parameter in
            if parameter.address == 1 { return self?.bodyPercent.load(ordering: .relaxed) ?? 45 }
            return self?.reverbPercent.load(ordering: .relaxed) ?? 30
        }
        parameterTree = tree
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var channelCapabilities: [NSNumber]? { [0, 1, 0, 2] }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        bus === output && Self.supports(format)
    }

    override func allocateRenderResources() throws {
        guard Self.supports(output.format), maximumFramesToRender > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        renderer = InstrumentRender(sampleRate: output.format.sampleRate, capacity: maximumFramesToRender)
    }

    override func deallocateRenderResources() {
        renderer = nil
        super.deallocateRenderResources()
    }

    override func reset() {
        super.reset()
        renderer?.clear()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [weak self] flags, timestamp, count, bus, output, events, _ in
            guard let self, let renderer = self.renderer else { return kAudioUnitErr_Uninitialized }
            guard bus == 0 else { return kAudioUnitErr_InvalidElement }
            guard count <= renderer.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            renderer.model.setReverb(self.reverbPercent.load(ordering: .relaxed) / 100)
            renderer.model.setBody(self.bodyPercent.load(ordering: .relaxed) / 100)
            return renderer.render(frames: count, time: timestamp.pointee.mSampleTime, output: output,
                                   events: events, setParameter: self.setParameter)
        }
    }

    private func setParameter(_ address: AUParameterAddress, _ percent: Float) {
        guard percent.isFinite else { return }
        let clamped = min(100, max(0, percent))
        switch address {
        case 0: reverbPercent.store(clamped, ordering: .relaxed)
        case 1: bodyPercent.store(clamped, ordering: .relaxed)
        default: break
        }
    }

    private static func supports(_ format: AVAudioFormat) -> Bool {
        (44_100...96_000).contains(format.sampleRate) &&
            (1...2).contains(format.channelCount) &&
            format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }
}

/// Per-instance render state. The host serializes render and resource lifecycle calls.
private final class InstrumentRender {
    let model: PianoModel
    let capacity: AUAudioFrameCount
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private var keys = [UInt16](repeating: 0, count: 128)
    private var soft = false

    init(sampleRate: Double, capacity: AUAudioFrameCount) {
        self.capacity = capacity
        model = PianoModel(sampleRate: sampleRate)
        scratchLeft = .allocate(capacity: Int(capacity))
        scratchRight = .allocate(capacity: Int(capacity))
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func clear() {
        model.releaseAll()
        for note in keys.indices { keys[note] = 0 }
        soft = false
    }

    func render(frames: AUAudioFrameCount, time: Float64, output: UnsafeMutablePointer<AudioBufferList>,
                events: UnsafePointer<AURenderEvent>?, setParameter: (AUParameterAddress, Float) -> Void) -> AUAudioUnitStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard (1...2).contains(buffers.count) else { return kAudioUnitErr_FormatNotSupported }
        let size = frames * UInt32(MemoryLayout<Float>.stride)
        for index in buffers.indices {
            if buffers[index].mData == nil {
                buffers[index].mData = UnsafeMutableRawPointer(index == 0 ? scratchLeft : scratchRight)
            } else if buffers[index].mDataByteSize < size {
                return kAudio_ParamError
            }
            buffers[index].mDataByteSize = size
        }
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers.count == 2 ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : scratchRight

        var rendered = 0
        var event = events
        while let current = event {
            let head = current.pointee.head
            let timeOffset = Double(head.eventSampleTime) - time
            if timeOffset.isFinite && timeOffset >= Double(frames) { break }
            let offset = max(rendered, timeOffset > 0 && timeOffset.isFinite ? Int(timeOffset) : 0)
            if offset > rendered {
                model.render(left + rendered, right + rendered, frames: UInt32(offset - rendered))
                rendered = offset
            }
            switch head.eventType {
            case .MIDI:
                let midi = current.pointee.MIDI
                if midi.length == 3, let message = PianoMIDI(status: midi.data.0, first: midi.data.1, second: midi.data.2) {
                    handle(message)
                }
            case .parameter, .parameterRamp:
                let parameter = current.pointee.parameter
                if parameter.value.isFinite {
                    setParameter(parameter.parameterAddress, parameter.value)
                    let amount = min(100, max(0, parameter.value)) / 100
                    switch parameter.parameterAddress {
                    case 0: model.setReverb(amount)
                    case 1: model.setBody(amount)
                    default: break
                    }
                }
            default:
                break
            }
            event = head.next.map { UnsafePointer($0) }
        }
        model.render(left + rendered, right + rendered, frames: frames - UInt32(rendered))
        if buffers.count == 1 {
            for index in 0..<Int(frames) { left[index] = (left[index] + right[index]) * 0.5 }
        }
        return noErr
    }

    private func handle(_ event: PianoMIDI) {
        switch event {
        case let .press(channel, note, velocity):
            keys[note] |= UInt16(1) << channel
            model.noteOn(note, velocity: Float(velocity) / 127, soft: soft)
        case let .release(channel, note):
            keys[note] &= ~(UInt16(1) << channel)
            if keys[note] == 0 { model.noteOff(note) }
        case let .damper(value):
            model.sustain(Float(value) / 127)
        case let .soft(down):
            soft = down
        case .panic:
            clear()
        }
    }
}
