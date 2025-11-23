//
//  VideoProcessor.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/11/20.
//

import Foundation
import AVFoundation
import Combine

class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var player: AVPlayer?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var equalizerBands: [EqualizerBand] = [
        EqualizerBand(frequency: 60, gain: 0, bandwidth: 1.0, name: "Bass"),
        EqualizerBand(frequency: 150, gain: 0, bandwidth: 1.0, name: "Low Mid"),
        EqualizerBand(frequency: 400, gain: 0, bandwidth: 1.0, name: "Mid Low"),
        EqualizerBand(frequency: 1000, gain: 0, bandwidth: 1.0, name: "Mid"),
        EqualizerBand(frequency: 2400, gain: 0, bandwidth: 1.0, name: "High Mid"),
        EqualizerBand(frequency: 15000, gain: 0, bandwidth: 1.0, name: "Treble")
    ]
    
    // Reverb parameters - enhanced for Hybrid Reverb style
    @Published var reverbDryWetMix: Float = 0.0  // 0-100%
    @Published var reverbRoomSize: Float = 0.5   // 0-1
    @Published var reverbDecayTime: Float = 2.5  // 0.1-10 seconds (increased range)
    
    // Reverb state - Enhanced Hybrid Reverb algorithm
    private var reverbEnabled: Bool = false
    
    // Multiple comb filters for early reflections (左右声道各8个，增加密度)
    private var combBuffersLeft: [[Float]] = []
    private var combBuffersRight: [[Float]] = []
    private var combIndicesLeft: [Int] = []
    private var combIndicesRight: [Int] = []
    private var combFeedback: Float = 0.84
    
    // All-pass filters for diffusion (左右声道各4个，增加扩散)
    private var allpassBuffersLeft: [[Float]] = []
    private var allpassBuffersRight: [[Float]] = []
    private var allpassIndicesLeft: [Int] = []
    private var allpassIndicesRight: [Int] = []
    private let allpassFeedback: Float = 0.5
    
    // Late reflections (长延迟线模拟尾音)
    private var lateReverbBufferLeft: [Float] = []
    private var lateReverbBufferRight: [Float] = []
    private var lateReverbIndexLeft: Int = 0
    private var lateReverbIndexRight: Int = 0
    
    // Damping filter for high frequency absorption
    private var dampingLeft: [Float] = []
    private var dampingRight: [Float] = []
    private let dampingCoeff: Float = 0.5
    
    // Pre-delay for spatial depth
    private var preDelayBuffer: [Float] = []
    private var preDelayIndex: Int = 0
    private let preDelayTime: Int = 882  // 20ms at 44.1kHz
    
    private var filters: [MultiChannelBiquadFilter] = []
    private var sampleRate: Float = 44100.0
    private var playerItem: AVPlayerItem?
    private var videoURL: URL?
    private var timeObserver: Any?
    
    // DC offset filter for removing low-frequency rumble
    private var dcFilterLeft: Float = 0.0
    private var dcFilterRight: Float = 0.0
    private let dcFilterCoeff: Float = 0.995
    
    // Processing state for warmup
    private var processedFrames: Int = 0
    private let warmupFrames: Int = 441000  // 10 seconds at 44.1kHz
    
    // Thread-safe flags for audio processing thread
    private var hasActiveEQ: Bool = false
    private var isReverbActive: Bool = false
    
    init() {
        setupAudioSession()
        setupFilters()
        setupReverb()
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
            try audioSession.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }
    
    private func setupFilters() {
        // Create a filter for each band
        filters = equalizerBands.map { _ in MultiChannelBiquadFilter() }
        updateAllFilters()
    }
    
    private func setupReverb() {
        // Enhanced Hybrid Reverb - 增加密度和扩散
        // Comb filter delays (8个，模拟更密集的早期反射)
        let combDelaysLeft = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let combDelaysRight = [1116 + 23, 1188 + 23, 1277 + 23, 1356 + 23, 
                               1422 + 23, 1491 + 23, 1557 + 23, 1617 + 23]
        
        // Allpass filter delays (4个，增加扩散)
        let allpassDelaysLeft = [556, 441, 341, 225]
        let allpassDelaysRight = [556 + 23, 441 + 23, 341 + 23, 225 + 23]
        
        // Initialize comb filters
        combBuffersLeft = combDelaysLeft.map { Array(repeating: 0.0, count: $0) }
        combBuffersRight = combDelaysRight.map { Array(repeating: 0.0, count: $0) }
        combIndicesLeft = Array(repeating: 0, count: combDelaysLeft.count)
        combIndicesRight = Array(repeating: 0, count: combDelaysRight.count)
        
        // Initialize allpass filters
        allpassBuffersLeft = allpassDelaysLeft.map { Array(repeating: 0.0, count: $0) }
        allpassBuffersRight = allpassDelaysRight.map { Array(repeating: 0.0, count: $0) }
        allpassIndicesLeft = Array(repeating: 0, count: allpassDelaysLeft.count)
        allpassIndicesRight = Array(repeating: 0, count: allpassDelaysRight.count)
        
        // Late reverb buffers (长尾音，模拟大空间)
        let lateReverbSize = 22050  // 0.5秒 at 44.1kHz
        lateReverbBufferLeft = Array(repeating: 0.0, count: lateReverbSize)
        lateReverbBufferRight = Array(repeating: 0.0, count: lateReverbSize)
        lateReverbIndexLeft = 0
        lateReverbIndexRight = 0
        
        // Damping filters (每个comb一个)
        dampingLeft = Array(repeating: 0.0, count: combDelaysLeft.count)
        dampingRight = Array(repeating: 0.0, count: combDelaysRight.count)
        
        // Pre-delay buffer
        preDelayBuffer = Array(repeating: 0.0, count: preDelayTime)
        preDelayIndex = 0
        
        reverbEnabled = false
    }
    
    private func updateAllFilters() {
        for (index, band) in equalizerBands.enumerated() {
            if index < filters.count {
                // Use wider bandwidth (lower Q) for more stable filtering
                let q = max(0.5, min(1.0 / max(band.bandwidth, 1.5), 3.0))
                filters[index].setPeakingEQ(
                    frequency: band.frequency,
                    sampleRate: sampleRate,
                    q: q,
                    gainDB: band.gain
                )
            }
        }
    }
    
    func loadVideo(from url: URL) {
        isProcessing = true
        videoURL = url
        
        // Clean up previous player
        cleanupPlayer()
        
        // Create asset
        let asset = AVURLAsset(url: url)
        
        // Create composition with audio processing
        createCompositionWithEQ(from: asset) { [weak self] composition, audioMix in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let composition = composition {
                    // Create player item with composition
                    let item = AVPlayerItem(asset: composition)
                    item.audioMix = audioMix
                    self.playerItem = item
                    
                    // Create player
                    self.player = AVPlayer(playerItem: item)
                    
                    // Setup time observer
                    self.setupTimeObserver()
                    
                    // Get duration
                    Task {
                        if let duration = try? await composition.load(.duration) {
                            await MainActor.run {
                                self.duration = CMTimeGetSeconds(duration)
                            }
                        }
                    }
                } else {
                    // Fallback to simple player
                    let item = AVPlayerItem(url: url)
                    self.playerItem = item
                    self.player = AVPlayer(playerItem: item)
                    self.setupTimeObserver()
                    
                    Task {
                        if let duration = try? await asset.load(.duration) {
                            await MainActor.run {
                                self.duration = CMTimeGetSeconds(duration)
                            }
                        }
                    }
                }
                
                self.isProcessing = false
            }
        }
    }
    
    private func createCompositionWithEQ(from asset: AVAsset, completion: @escaping (AVMutableComposition?, AVAudioMix?) -> Void) {
        Task {
            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
                completion(nil, nil)
                return
            }
            
            // Get audio format to extract sample rate
            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
               let formatDescription = formatDescriptions.first {
                let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
                if let asbd = audioStreamBasicDescription {
                    await MainActor.run {
                        self.sampleRate = Float(asbd.pointee.mSampleRate)
                        self.updateAllFilters()
                    }
                }
            }
            
            let composition = AVMutableComposition()
            
            // Add video track
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(nil, nil)
                return
            }
            
            // Add audio track
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(nil, nil)
                return
            }
            
            do {
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
                try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                
                // Create audio mix with EQ
                let audioMix = AVMutableAudioMix()
                let inputParams = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
                
                // Apply audio processing using MTAudioProcessingTap
                inputParams.audioTapProcessor = createAudioTap()
                
                audioMix.inputParameters = [inputParams]
                
                completion(composition, audioMix)
            } catch {
                print("Error creating composition: \(error)")
                completion(nil, nil)
            }
        }
    }
    
    private func createAudioTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { (tap, clientInfo, tapStorageOut) in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in },
            prepare: { (tap, maxFrames, processingFormat) in
                // Reset all processing state when starting playback/export
                let clientInfo = MTAudioProcessingTapGetStorage(tap)
                let processor = Unmanaged<VideoProcessor>.fromOpaque(clientInfo).takeUnretainedValue()
                processor.resetProcessingState()
            },
            unprepare: { tap in },
            process: { (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in
                var timeRange = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
                
                if status != noErr { return }
                
                let clientInfo = MTAudioProcessingTapGetStorage(tap)
                
                let processor = Unmanaged<VideoProcessor>.fromOpaque(clientInfo).takeUnretainedValue()
                processor.applyAudioEffects(to: bufferListInOut, frameCount: numberFrames)
            }
        )
        
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        
        if status == noErr, let tap = tap {
            return tap.takeUnretainedValue()
        }
        return nil
    }
    
    private func resetProcessingState() {
        // Reset frame counter
        processedFrames = 0
        
        // Reset DC filters
        dcFilterLeft = 0.0
        dcFilterRight = 0.0
        
        // Reset all EQ filters
        for filter in filters {
            filter.reset()
        }
        
        // Reset reverb buffers if enabled
        if reverbEnabled {
            for i in 0..<combBuffersLeft.count {
                combBuffersLeft[i] = Array(repeating: 0, count: combBuffersLeft[i].count)
                combBuffersRight[i] = Array(repeating: 0, count: combBuffersRight[i].count)
                combIndicesLeft[i] = 0
                combIndicesRight[i] = 0
            }
            for i in 0..<allpassBuffersLeft.count {
                allpassBuffersLeft[i] = Array(repeating: 0, count: allpassBuffersLeft[i].count)
                allpassBuffersRight[i] = Array(repeating: 0, count: allpassBuffersRight[i].count)
                allpassIndicesLeft[i] = 0
                allpassIndicesRight[i] = 0
            }
            dampingLeft = Array(repeating: 0.0, count: dampingLeft.count)
            dampingRight = Array(repeating: 0.0, count: dampingRight.count)
            lateReverbBufferLeft = Array(repeating: 0, count: lateReverbBufferLeft.count)
            lateReverbBufferRight = Array(repeating: 0, count: lateReverbBufferRight.count)
            lateReverbIndexLeft = 0
            lateReverbIndexRight = 0
            preDelayBuffer = Array(repeating: 0, count: preDelayTime)
            preDelayIndex = 0
        }
    }
    
    private func applyAudioEffects(to bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // Use thread-safe flags instead of accessing @Published properties
        let eqActive = hasActiveEQ
        let reverbActive = isReverbActive
        
        // If no effects are active, just pass through
        if !eqActive && !reverbActive {
            return
        }
        
        let bufferCount = Int(audioBufferList.count)
        
        // Process mono or stereo
        if bufferCount == 1 {
            // Mono processing
            guard let buffer = audioBufferList.first,
                  let data = buffer.mData else { return }
            
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.bindMemory(to: Float.self, capacity: count)
            
            // Process each sample
            for i in 0..<count {
                var sample = samples[i]
                
                // Calculate fade-in factor for warmup period
                let fadeIn: Float
                if processedFrames < warmupFrames {
                    fadeIn = Float(processedFrames) / Float(warmupFrames)
                    processedFrames += 1
                } else {
                    fadeIn = 1.0
                }
                
                if !sample.isFinite {
                    sample = 0
                }
                
                // Apply DC offset filter first
                dcFilterLeft = dcFilterCoeff * dcFilterLeft + (1.0 - dcFilterCoeff) * sample
                sample = sample - dcFilterLeft
                
                // Apply all filters in series with denormal protection (only if EQ is active)
                if hasActiveEQ {
                    for filter in filters {
                        sample = filter.processLeft(sample)
                        if !sample.isFinite || abs(sample) < 1e-10 {
                            sample = 0
                            break
                        }
                    }
                }
                
                // Apply reverb if enabled
                if reverbEnabled && reverbDryWetMix > 0.01 {
                    sample = applyReverbMono(sample)
                }
                
                // 温和的软削波（使用tanh，仅当信号较大时）
                let absSample = abs(sample)
                if absSample > 0.9 {
                    // 软削波曲线，保持平滑
                    let sign = sample > 0 ? Float(1.0) : Float(-1.0)
                    sample = sign * tanhf(absSample * 0.85)
                }
                
                // 最终安全限制
                sample = max(-0.98, min(0.98, sample))
                
                // Apply fade-in
                sample *= fadeIn
                
                samples[i] = sample
            }
        } else if bufferCount >= 2 {
            // Stereo processing
            guard let leftBuffer = audioBufferList[0].mData,
                  let rightBuffer = audioBufferList[1].mData else { return }
            
            let count = Int(audioBufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            let leftSamples = leftBuffer.bindMemory(to: Float.self, capacity: count)
            let rightSamples = rightBuffer.bindMemory(to: Float.self, capacity: count)
            
            // Process each sample
            for i in 0..<count {
                var leftSample = leftSamples[i]
                var rightSample = rightSamples[i]
                
                // Calculate fade-in factor for warmup period
                let fadeIn: Float
                if processedFrames < warmupFrames {
                    fadeIn = Float(processedFrames) / Float(warmupFrames)
                    processedFrames += 1
                } else {
                    fadeIn = 1.0
                }
                
                if !leftSample.isFinite { leftSample = 0 }
                if !rightSample.isFinite { rightSample = 0 }
                
                // Apply DC offset filter first
                dcFilterLeft = dcFilterCoeff * dcFilterLeft + (1.0 - dcFilterCoeff) * leftSample
                dcFilterRight = dcFilterCoeff * dcFilterRight + (1.0 - dcFilterCoeff) * rightSample
                leftSample = leftSample - dcFilterLeft
                rightSample = rightSample - dcFilterRight
                
                // Apply all filters in series with denormal protection (only if EQ is active)
                if hasActiveEQ {
                    for filter in filters {
                        leftSample = filter.processLeft(leftSample)
                        rightSample = filter.processRight(rightSample)
                        
                        if !leftSample.isFinite || abs(leftSample) < 1e-10 { leftSample = 0 }
                        if !rightSample.isFinite || abs(rightSample) < 1e-10 { rightSample = 0 }
                    }
                }
                
                // Apply reverb if enabled
                if reverbEnabled && reverbDryWetMix > 0.01 {
                    leftSample = applyReverbStereo(leftSample, isLeft: true)
                    rightSample = applyReverbStereo(rightSample, isLeft: false)
                }
                
                // 温和的软削波（使用tanh，仅当信号较大时）
                let absLeft = abs(leftSample)
                let absRight = abs(rightSample)
                
                if absLeft > 0.9 {
                    let sign = leftSample > 0 ? Float(1.0) : Float(-1.0)
                    leftSample = sign * tanhf(absLeft * 0.85)
                }
                if absRight > 0.9 {
                    let sign = rightSample > 0 ? Float(1.0) : Float(-1.0)
                    rightSample = sign * tanhf(absRight * 0.85)
                }
                
                // 最终安全限制
                leftSample = max(-0.98, min(0.98, leftSample))
                rightSample = max(-0.98, min(0.98, rightSample))
                
                // Apply fade-in
                leftSample *= fadeIn
                rightSample *= fadeIn
                
                leftSamples[i] = leftSample
                rightSamples[i] = rightSample
            }
        }
    }
    
    // Freeverb算法的混响处理
    private func applyReverbMono(_ input: Float) -> Float {
        return applyReverbChannel(input, 
                                  combBuffers: &combBuffersLeft, 
                                  combIndices: &combIndicesLeft, 
                                  allpassBuffers: &allpassBuffersLeft, 
                                  allpassIndices: &allpassIndicesLeft,
                                  damping: &dampingLeft)
    }
    
    private func applyReverbStereo(_ input: Float, isLeft: Bool) -> Float {
        if isLeft {
            return applyReverbChannel(input, 
                                      combBuffers: &combBuffersLeft, 
                                      combIndices: &combIndicesLeft, 
                                      allpassBuffers: &allpassBuffersLeft, 
                                      allpassIndices: &allpassIndicesLeft,
                                      damping: &dampingLeft)
        } else {
            return applyReverbChannel(input, 
                                      combBuffers: &combBuffersRight, 
                                      combIndices: &combIndicesRight, 
                                      allpassBuffers: &allpassBuffersRight, 
                                      allpassIndices: &allpassIndicesRight,
                                      damping: &dampingRight)
        }
    }
    
    private func applyReverbChannel(_ input: Float, 
                                    combBuffers: inout [[Float]], 
                                    combIndices: inout [Int],
                                    allpassBuffers: inout [[Float]],
                                    allpassIndices: inout [Int],
                                    damping: inout [Float]) -> Float {
        guard reverbEnabled else { return input }
        
        // Mix range: UI shows 0-100%, but actual effect is 0-40% (80% of 50%)
        let wetMix = reverbDryWetMix / 250.0
        let dryMix = 1.0 - wetMix
        
        // Pre-delay for spatial depth (增加空间感)
        let preDelayedInput = preDelayBuffer[preDelayIndex]
        preDelayBuffer[preDelayIndex] = input
        preDelayIndex = (preDelayIndex + 1) % preDelayTime
        
        // Enhanced feedback scaling (0.75-0.95 range for longer tail)
        let roomScaleFeedback = 0.75 + (reverbRoomSize * 0.2)
        
        // Decay time affects both feedback and damping
        // Longer decay = less damping, more feedback
        let decayScale = min(reverbDecayTime / 10.0, 1.0)
        let enhancedFeedback = roomScaleFeedback + (decayScale * 0.1)
        let decayDamping = 1.0 - (decayScale * 0.4)
        
        // Process through parallel comb filters (early reflections)
        var combOutput: Float = 0.0
        for i in 0..<combBuffers.count {
            let bufferSize = combBuffers[i].count
            let readIndex = combIndices[i]
            
            // Read delayed sample
            var delayedSample = combBuffers[i][readIndex]
            
            // Apply damping filter (one-pole lowpass) - absorb high frequencies
            damping[i] = delayedSample * (1.0 - dampingCoeff * decayDamping) + damping[i] * dampingCoeff * decayDamping
            delayedSample = damping[i]
            
            // Feedback with enhanced coefficient for longer tail
            combBuffers[i][readIndex] = preDelayedInput + delayedSample * min(enhancedFeedback, 0.95)
            
            // Accumulate output
            combOutput += delayedSample
            
            // Increment index
            combIndices[i] = (readIndex + 1) % bufferSize
        }
        
        // Average the comb outputs
        combOutput /= Float(combBuffers.count)
        
        // Process through series allpass filters for diffusion (smoothness)
        var allpassOutput = combOutput
        for i in 0..<allpassBuffers.count {
            let bufferSize = allpassBuffers[i].count
            let readIndex = allpassIndices[i]
            
            let delayedSample = allpassBuffers[i][readIndex]
            let input_ap = allpassOutput
            
            // Allpass formula: output = -input + delayed + (input * feedback)
            allpassOutput = -input_ap + delayedSample
            allpassBuffers[i][readIndex] = input_ap + delayedSample * allpassFeedback
            
            allpassIndices[i] = (readIndex + 1) % bufferSize
        }
        
        // Mix dry and wet signals with controlled wet gain to prevent clipping
        let wetGain = wetMix * 0.7  // Further reduced to prevent overload
        let output = input * dryMix + allpassOutput * wetGain
        
        // Gentle soft limiting only when necessary
        let absOutput = abs(output)
        if absOutput > 0.9 {
            let sign = output > 0 ? Float(1.0) : Float(-1.0)
            return sign * tanhf(absOutput * 0.85)
        }
        return output
    }
    
    private func incrementReverbIndex() {
        // No longer needed with new algorithm
    }
    
    func disableReverb() {
        reverbEnabled = false
        isReverbActive = false
        // Clear all reverb buffers
        for i in 0..<combBuffersLeft.count {
            combBuffersLeft[i] = Array(repeating: 0, count: combBuffersLeft[i].count)
            combBuffersRight[i] = Array(repeating: 0, count: combBuffersRight[i].count)
            combIndicesLeft[i] = 0
            combIndicesRight[i] = 0
        }
        for i in 0..<allpassBuffersLeft.count {
            allpassBuffersLeft[i] = Array(repeating: 0, count: allpassBuffersLeft[i].count)
            allpassBuffersRight[i] = Array(repeating: 0, count: allpassBuffersRight[i].count)
            allpassIndicesLeft[i] = 0
            allpassIndicesRight[i] = 0
        }
        dampingLeft = Array(repeating: 0.0, count: dampingLeft.count)
        dampingRight = Array(repeating: 0.0, count: dampingRight.count)
        lateReverbBufferLeft = Array(repeating: 0, count: lateReverbBufferLeft.count)
        lateReverbBufferRight = Array(repeating: 0, count: lateReverbBufferRight.count)
        lateReverbIndexLeft = 0
        lateReverbIndexRight = 0
        preDelayBuffer = Array(repeating: 0, count: preDelayTime)
        preDelayIndex = 0
    }
    
    func enableReverb() {
        reverbEnabled = true
        isReverbActive = true
    }
    
    private func setupTimeObserver() {
        guard let player = player else { return }
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
        
        // Observe playing state
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    func updateEQ(bandIndex: Int, gain: Float) {
        guard bandIndex < equalizerBands.count else { return }
        equalizerBands[bandIndex].gain = gain
        
        // Update the specific filter smoothly with wider bandwidth
        if bandIndex < filters.count {
            let band = equalizerBands[bandIndex]
            let q = max(0.5, min(1.0 / max(band.bandwidth, 1.5), 3.0))
            filters[bandIndex].setPeakingEQ(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: q,
                gainDB: gain
            )
        }
        
        // Update thread-safe flag
        hasActiveEQ = equalizerBands.contains { abs($0.gain) > 0.1 }
    }
    
    func disableEQ() {
        // 将所有滤波器的增益设置为0,但不修改equalizerBands的值
        for i in 0..<filters.count {
            let band = equalizerBands[i]
            filters[i].setPeakingEQ(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: 1.0 / band.bandwidth,
                gainDB: 0  // 禁用时增益为0
            )
        }
        hasActiveEQ = false
    }
    
    func play() {
        player?.play()
    }
    
    func pause() {
        player?.pause()
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
    }
    
    func resetEQ() {
        for i in 0..<equalizerBands.count {
            equalizerBands[i].gain = 0
            updateEQ(bandIndex: i, gain: 0)
        }
        hasActiveEQ = false
    }
    
    func resetReverb() {
        reverbDryWetMix = 0.0
        reverbRoomSize = 0.5
        reverbDecayTime = 2.5
    }
    
    private func cleanupPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        playerItem = nil
        cancellables.removeAll()
    }
    
    deinit {
        cleanupPlayer()
    }
}

struct EqualizerBand {
    var frequency: Float
    var gain: Float
    var bandwidth: Float
    var name: String
}
