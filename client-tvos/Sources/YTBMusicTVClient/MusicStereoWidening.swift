import AVFoundation
import AudioToolbox
import CoreMedia
import MediaToolbox

// Real-time mid/side width adjustment for decoded AVPlayer audio.
// On tvOS 27, the special track-mix audio tap works for remote/HLS streams,
// instead of requiring us to replace AVPlayer and its crossfade/preload engine.
//
// Keep center information intact relative to both channels. Apply only a
// modest side gain and fixed headroom; no reverb, Haas delay, EQ, or phase shift.
// The effect works on existing stereo content (mono content remains mono).
private final class StereoWidthTapState {
    let sideGain: Float
    private let headroom: Float = 0.87

    // Written by the tap's prepare callback before process is invoked.
    private var format = AudioStreamBasicDescription()

    init(strength: Double) {
        sideGain = Float(1 + min(0.55, max(0.12, strength)))
    }

    func prepare(format: AudioStreamBasicDescription) {
        self.format = format
    }

    @inline(__always)
    private func widen(_ l: Float, _ r: Float) -> (Float, Float) {
        let middle = (l + r) * 0.5
        let side = (l - r) * 0.5 * sideGain
        // Preserve an unchanged, stable center with headroom that prevents
        // typical full-scale hard-panned signals from clipping. The soft
        // ceiling only catches pathological anti-phase near-0 dBFS peaks.
        let left = (middle + side) * headroom
        let right = (middle - side) * headroom
        return (max(-1, min(1, left)), max(-1, min(1, right)))
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, format.mChannelsPerFrame == 2,
              format.mFormatID == kAudioFormatLinearPCM else { return }
        let flags = format.mFormatFlags
        let noninterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        let floating = (flags & kAudioFormatFlagIsFloat) != 0
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        if floating && format.mBitsPerChannel == 32 {
            if noninterleaved {
                guard buffers.count >= 2,
                      let rawL = buffers[0].mData, let rawR = buffers[1].mData,
                      Int(buffers[0].mDataByteSize) >= frames * MemoryLayout<Float>.size,
                      Int(buffers[1].mDataByteSize) >= frames * MemoryLayout<Float>.size else { return }
                let left = rawL.assumingMemoryBound(to: Float.self)
                let right = rawR.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    let (l, r) = widen(left[i], right[i])
                    left[i] = l
                    right[i] = r
                }
            } else {
                guard buffers.count >= 1, let raw = buffers[0].mData,
                      Int(buffers[0].mDataByteSize) >= frames * 2 * MemoryLayout<Float>.size else { return }
                let samples = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    let (l, r) = widen(samples[i * 2], samples[i * 2 + 1])
                    samples[i * 2] = l
                    samples[i * 2 + 1] = r
                }
            }
        } else if !floating && format.mBitsPerChannel == 16 &&
                  (flags & kAudioFormatFlagIsSignedInteger) != 0 {
            if noninterleaved {
                guard buffers.count >= 2,
                      let rawL = buffers[0].mData, let rawR = buffers[1].mData,
                      Int(buffers[0].mDataByteSize) >= frames * MemoryLayout<Int16>.size,
                      Int(buffers[1].mDataByteSize) >= frames * MemoryLayout<Int16>.size else { return }
                let left = rawL.assumingMemoryBound(to: Int16.self)
                let right = rawR.assumingMemoryBound(to: Int16.self)
                for i in 0..<frames {
                    let (l, r) = widen(Float(left[i]) / 32768, Float(right[i]) / 32768)
                    left[i] = Int16(max(-32768, min(32767, Int(l * 32767))))
                    right[i] = Int16(max(-32768, min(32767, Int(r * 32767))))
                }
            } else {
                guard buffers.count >= 1, let raw = buffers[0].mData,
                      Int(buffers[0].mDataByteSize) >= frames * 2 * MemoryLayout<Int16>.size else { return }
                let samples = raw.assumingMemoryBound(to: Int16.self)
                for i in 0..<frames {
                    let (l, r) = widen(Float(samples[2 * i]) / 32768, Float(samples[2 * i + 1]) / 32768)
                    samples[2 * i] = Int16(max(-32768, min(32767, Int(l * 32767))))
                    samples[2 * i + 1] = Int16(max(-32768, min(32767, Int(r * 32767))))
                }
            }
        }
        // If Apple supplies an unfamiliar layout or sample encoding, pass
        // through the original samples. Silence/glitches are never substituted.
    }
}

enum MusicStereoWidening {
    /// Install a DSP tap directly in the existing AVPlayerItem audio pipeline.
    /// False means no effect was installed; ordinary audio stays available.
    @discardableResult
    static func install(on item: AVPlayerItem, strength: Double) -> Bool {
        guard #available(tvOS 27.0, *) else { return false }
        return installWithTrackMix(on: item, strength: strength)
    }

    @available(tvOS 27.0, *)
    private static func installWithTrackMix(on item: AVPlayerItem, strength: Double) -> Bool {
        let state = StereoWidthTapState(strength: strength)
        let pointer = Unmanaged.passRetained(state).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: pointer,
            init: { _, clientInfo, storage in
                storage.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<StereoWidthTapState>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).release()
            },
            prepare: { tap, _, description in
                let state = Unmanaged<StereoWidthTapState>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).takeUnretainedValue()
                state.prepare(format: description.pointee)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, buffers, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, buffers, flagsOut, nil, framesOut
                )
                guard status == noErr else {
                    framesOut.pointee = 0
                    return
                }
                let state = Unmanaged<StereoWidthTapState>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)
                ).takeUnretainedValue()
                state.process(buffers, frames: Int(framesOut.pointee))
            }
        )

        // Request stereo planar Float32 PCM, but check the actual prepared
        // format because AVFoundation is permitted to supply a different one.
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var preferred: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &preferred
        )
        guard formatStatus == noErr, let preferred else {
            Unmanaged<StereoWidthTapState>.fromOpaque(pointer).release()
            return false
        }

        var managedTap: MTAudioProcessingTap?
        let result = MTAudioProcessingTapCreateWithPreferredFormat(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            preferred, &managedTap
        )
        guard result == noErr, let tap = managedTap else {
            Unmanaged<StereoWidthTapState>.fromOpaque(pointer).release()
            return false
        }

        let parameters = AVMutableAudioMixInputParameters()
        // tvOS 27 AVAudioMixInputParametersTrackMixID == 0. The default
        // factory initializes this to the complete decoded track mix.
        parameters.trackID = 0
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return true
    }

    static func disable(on item: AVPlayerItem) {
        item.audioMix = nil
    }
}
