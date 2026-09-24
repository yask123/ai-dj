import AVFoundation

/// AVAudioEngine host: the DJCore renders inside one AVAudioSourceNode, then Apple's peak limiter.
final class AudioEngine: @unchecked Sendable {
    let core = DJCore(sampleRate: 44100)
    private let engine = AVAudioEngine()

    init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let core = self.core
        let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let l = list[0].mData!.assumingMemoryBound(to: Float.self)
            let r = list.count > 1 ? list[1].mData!.assumingMemoryBound(to: Float.self) : l
            core.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(src)
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(limiter)
        engine.connect(src, to: limiter, format: fmt)
        engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try? engine.start()
    }
}
