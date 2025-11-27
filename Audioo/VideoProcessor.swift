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
    
    // Audio format detection
    private var isFloatFormat: Bool = true
    private var isIntFormat: Bool = false
    private var bitsPerChannel: UInt32 = 32
    
    // DC offset filter for removing low-frequency rumble
    private var dcFilterLeft: Float = 0.0
    private var dcFilterRight: Float = 0.0
    private let dcFilterCoeff: Float = 0.99  // Gentler cutoff to avoid pumping artifacts
    
    // Reusable buffers for Int16 processing (allocated once, reused)
    private var tempMonoBuffer: [Float] = []
    private var tempLeftBuffer: [Float] = []
    private var tempRightBuffer: [Float] = []
    private var lastBufferSize: Int = 0
    
    // Fixed input gain (no analysis needed)
    private let inputGain: Float = 1.0
    
    // Loudness tracking (for future metering)
    private var rmsLeft: Float = 0.0
    private var rmsRight: Float = 0.0
    private let rmsCoeff: Float = 0.9995  // Very slow attack for loudness measurement
    
    // Mastering chain
    private var masteringGain: Float = 1.0  // 最终 mastering 增益
    
    // Thread-safe flags for audio processing thread
    private var hasActiveEQ: Bool = false
    private var isReverbActive: Bool = false
    private var eqCompensationGain: Float = 1.0  // 动态 EQ 补偿增益（相对 EQ 模式）
    private var makeupGain: Float = 1.0  // Makeup gain 用于恢复响度
    
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
        // 安全限制：最大延迟 10000 samples (~227ms at 44.1kHz)
        let combDelaysLeft = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let combDelaysRight = [1116 + 23, 1188 + 23, 1277 + 23, 1356 + 23, 
                               1422 + 23, 1491 + 23, 1557 + 23, 1617 + 23]
        
        // Allpass filter delays (4个，增加扩散)
        let allpassDelaysLeft = [556, 441, 341, 225]
        let allpassDelaysRight = [556 + 23, 441 + 23, 341 + 23, 225 + 23]
        
        // 安全检查：确保延迟值合理
        let maxReverbDelay = 10000  // 最大延迟
        
        // Initialize comb filters with safety checks
        combBuffersLeft = combDelaysLeft.map { 
            let size = min($0, maxReverbDelay)
            return Array(repeating: 0.0, count: max(1, size))
        }
        combBuffersRight = combDelaysRight.map { 
            let size = min($0, maxReverbDelay)
            return Array(repeating: 0.0, count: max(1, size))
        }
        combIndicesLeft = Array(repeating: 0, count: combDelaysLeft.count)
        combIndicesRight = Array(repeating: 0, count: combDelaysRight.count)
        
        // Initialize allpass filters with safety checks
        allpassBuffersLeft = allpassDelaysLeft.map { 
            let size = min($0, maxReverbDelay)
            return Array(repeating: 0.0, count: max(1, size))
        }
        allpassBuffersRight = allpassDelaysRight.map { 
            let size = min($0, maxReverbDelay)
            return Array(repeating: 0.0, count: max(1, size))
        }
        allpassIndicesLeft = Array(repeating: 0, count: allpassDelaysLeft.count)
        allpassIndicesRight = Array(repeating: 0, count: allpassDelaysRight.count)
        
        // Late reverb buffers (长尾音，模拟大空间)
        // 限制最大 0.5 秒
        let lateReverbSize = min(22050, 44100)  // 最多 1 秒
        lateReverbBufferLeft = Array(repeating: 0.0, count: lateReverbSize)
        lateReverbBufferRight = Array(repeating: 0.0, count: lateReverbSize)
        lateReverbIndexLeft = 0
        lateReverbIndexRight = 0
        
        // Damping filters (每个comb一个)
        dampingLeft = Array(repeating: 0.0, count: combDelaysLeft.count)
        dampingRight = Array(repeating: 0.0, count: combDelaysRight.count)
        
        // Pre-delay buffer
        let safePreDelayTime = min(preDelayTime, 4410)  // 最多 100ms at 44.1kHz
        preDelayBuffer = Array(repeating: 0.0, count: safePreDelayTime)
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
                
                // Get ASBD to detect audio format
                let asbd = processingFormat.pointee
                
                // Store format information
                processor.sampleRate = Float(asbd.mSampleRate)
                processor.isFloatFormat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                processor.isIntFormat = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
                processor.bitsPerChannel = asbd.mBitsPerChannel
                
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
        
        if status == noErr, let unwrappedTap = tap {
            return unwrappedTap.takeRetainedValue()
        }
        return nil
    }
    
    private func resetProcessingState() {
        // Reset DC filters
        dcFilterLeft = 0.0
        dcFilterRight = 0.0
        
        // Reset all EQ filters
        for filter in filters {
            filter.reset()
        }
        
        // Reset loudness tracking
        rmsLeft = 0.0
        rmsRight = 0.0
        
        // Reset reverb buffers if enabled
        if reverbEnabled {
            // 安全限制：最大缓冲区大小
            let maxBufferSize = 100000  // ~2.3秒 at 44.1kHz
            
            for i in 0..<combBuffersLeft.count {
                let leftSize = combBuffersLeft[i].count
                let rightSize = combBuffersRight[i].count
                
                // 验证大小合理性
                if leftSize > 0 && leftSize <= maxBufferSize {
                    combBuffersLeft[i] = Array(repeating: 0.0, count: leftSize)
                } else {
                    print("⚠️ Warning: combBuffersLeft[\(i)] size \(leftSize) invalid, resetting to 1116")
                    combBuffersLeft[i] = Array(repeating: 0.0, count: 1116)
                }
                
                if rightSize > 0 && rightSize <= maxBufferSize {
                    combBuffersRight[i] = Array(repeating: 0.0, count: rightSize)
                } else {
                    print("⚠️ Warning: combBuffersRight[\(i)] size \(rightSize) invalid, resetting to 1139")
                    combBuffersRight[i] = Array(repeating: 0.0, count: 1139)
                }
                
                combIndicesLeft[i] = 0
                combIndicesRight[i] = 0
            }
            
            for i in 0..<allpassBuffersLeft.count {
                let leftSize = allpassBuffersLeft[i].count
                let rightSize = allpassBuffersRight[i].count
                
                if leftSize > 0 && leftSize <= maxBufferSize {
                    allpassBuffersLeft[i] = Array(repeating: 0.0, count: leftSize)
                } else {
                    print("⚠️ Warning: allpassBuffersLeft[\(i)] size \(leftSize) invalid, resetting to 556")
                    allpassBuffersLeft[i] = Array(repeating: 0.0, count: 556)
                }
                
                if rightSize > 0 && rightSize <= maxBufferSize {
                    allpassBuffersRight[i] = Array(repeating: 0.0, count: rightSize)
                } else {
                    print("⚠️ Warning: allpassBuffersRight[\(i)] size \(rightSize) invalid, resetting to 579")
                    allpassBuffersRight[i] = Array(repeating: 0.0, count: 579)
                }
                
                allpassIndicesLeft[i] = 0
                allpassIndicesRight[i] = 0
            }
            
            dampingLeft = Array(repeating: 0.0, count: dampingLeft.count)
            dampingRight = Array(repeating: 0.0, count: dampingRight.count)
            
            // Reset late reverb buffers with safety checks
            let lateLeftSize = lateReverbBufferLeft.count
            let lateRightSize = lateReverbBufferRight.count
            
            if lateLeftSize > 0 && lateLeftSize <= maxBufferSize {
                lateReverbBufferLeft = Array(repeating: 0.0, count: lateLeftSize)
            } else {
                print("⚠️ Warning: lateReverbBufferLeft size \(lateLeftSize) invalid, resetting to 22050")
                lateReverbBufferLeft = Array(repeating: 0.0, count: 22050)
            }
            
            if lateRightSize > 0 && lateRightSize <= maxBufferSize {
                lateReverbBufferRight = Array(repeating: 0.0, count: lateRightSize)
            } else {
                print("⚠️ Warning: lateReverbBufferRight size \(lateRightSize) invalid, resetting to 22050")
                lateReverbBufferRight = Array(repeating: 0.0, count: 22050)
            }
            
            lateReverbIndexLeft = 0
            lateReverbIndexRight = 0
            
            // Reset pre-delay buffer with safety check
            let preDelaySize = preDelayBuffer.count
            if preDelaySize > 0 && preDelaySize <= maxBufferSize {
                preDelayBuffer = Array(repeating: 0.0, count: preDelaySize)
            } else {
                print("⚠️ Warning: preDelayBuffer size \(preDelaySize) invalid, resetting to \(preDelayTime)")
                preDelayBuffer = Array(repeating: 0.0, count: preDelayTime)
            }
            preDelayIndex = 0
        }
    }
    
    private func applyAudioEffects(to bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // Use thread-safe flags for conditional processing
        
        // Handle Int16 format (common for export)
        if isIntFormat && bitsPerChannel == 16 {
            applyAudioEffectsInt16(to: bufferList, frameCount: frameCount)
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
                
                if !sample.isFinite {
                    sample = 0
                }
                
                // Apply input gain
                sample *= inputGain
                
                // Pre-limit input to prevent cascading overload
                sample = max(-0.9, min(0.9, sample))
                
                // Apply DC offset filter
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
                
                // Final safe output limit
                sample = max(-0.9, min(0.9, sample))
                
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
                
                if !leftSample.isFinite { leftSample = 0 }
                if !rightSample.isFinite { rightSample = 0 }
                
                // Apply input gain
                leftSample *= inputGain
                rightSample *= inputGain
                
                // Pre-limit input to prevent cascading overload
                leftSample = max(-0.9, min(0.9, leftSample))
                rightSample = max(-0.9, min(0.9, rightSample))
                
                // Apply DC offset filter - gentler approach
                // Only remove strong DC component, don't over-correct
                dcFilterLeft = dcFilterCoeff * dcFilterLeft + (1.0 - dcFilterCoeff) * leftSample
                dcFilterRight = dcFilterCoeff * dcFilterRight + (1.0 - dcFilterCoeff) * rightSample
                leftSample = leftSample - dcFilterLeft * 0.5  // Only remove 50% of detected offset
                rightSample = rightSample - dcFilterRight * 0.5
                
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
                
                // Final safe output limit
                leftSample = max(-0.9, min(0.9, leftSample))
                rightSample = max(-0.9, min(0.9, rightSample))
                
                leftSamples[i] = leftSample
                rightSamples[i] = rightSample
            }
        }
    }
    
    // Process Int16 audio format (common for export)
    private func applyAudioEffectsInt16(to bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        let bufferCount = Int(audioBufferList.count)
        let count = Int(frameCount)
        
        // Ensure temp buffers are allocated and sized correctly
        if count > lastBufferSize {
            tempMonoBuffer = Array(repeating: 0.0, count: count)
            tempLeftBuffer = Array(repeating: 0.0, count: count)
            tempRightBuffer = Array(repeating: 0.0, count: count)
            lastBufferSize = count
        }
        
        if bufferCount == 1 {
            // Mono processing
            guard let buffer = audioBufferList.first,
                  let data = buffer.mData else { return }
            
            let samplesInt16 = data.bindMemory(to: Int16.self, capacity: count)
            
            // Int16 -> Float [-1, 1] directly into temp buffer
            for i in 0..<count {
                tempMonoBuffer[i] = Float(samplesInt16[i]) / 32768.0
            }
            
            // Process as mono
            processFloatBufferMono(&tempMonoBuffer, count: count)
            
            // Float -> Int16 with safe headroom
            let outputLimit: Float = 0.5
            for i in 0..<count {
                let v = max(-outputLimit, min(outputLimit, tempMonoBuffer[i]))
                samplesInt16[i] = Int16(v * 32767.0)
            }
        } else if bufferCount >= 2 {
            // Stereo processing
            guard let leftBuffer = audioBufferList[0].mData,
                  let rightBuffer = audioBufferList[1].mData else { return }
            
            let leftSamplesInt16 = leftBuffer.bindMemory(to: Int16.self, capacity: count)
            let rightSamplesInt16 = rightBuffer.bindMemory(to: Int16.self, capacity: count)
            
            // Int16 -> Float [-1, 1] directly into temp buffers
            for i in 0..<count {
                tempLeftBuffer[i] = Float(leftSamplesInt16[i]) / 32768.0
                tempRightBuffer[i] = Float(rightSamplesInt16[i]) / 32768.0
            }
            
            // Process stereo
            processFloatBufferStereo(&tempLeftBuffer, &tempRightBuffer, count: count)
            
            // Float -> Int16 with safe headroom
            let outputLimit: Float = 0.5
            for i in 0..<count {
                let leftV = max(-outputLimit, min(outputLimit, tempLeftBuffer[i]))
                let rightV = max(-outputLimit, min(outputLimit, tempRightBuffer[i]))
                leftSamplesInt16[i] = Int16(leftV * 32767.0)
                rightSamplesInt16[i] = Int16(rightV * 32767.0)
            }
        }
    }
    
    // Process mono float buffer
    private func processFloatBufferMono(_ samples: inout [Float], count: Int) {
        for i in 0..<count {
            var sample = samples[i]
            
            if !sample.isFinite {
                sample = 0
            }
            
            // Apply input gain
            sample *= inputGain
            
            // Pre-limit input to prevent cascading overload
            sample = max(-0.9, min(0.9, sample))
            
            // Apply DC offset filter - gentler approach
            // Only remove strong DC component, don't over-correct
            dcFilterLeft = dcFilterCoeff * dcFilterLeft + (1.0 - dcFilterCoeff) * sample
            sample = sample - dcFilterLeft * 0.5  // Only remove 50% of detected offset to avoid over-correction
            
            // Apply all filters in series with denormal protection (only if EQ is active)
            if hasActiveEQ {
                // 纯减法 EQ: 先应用全局衰减
                sample *= eqCompensationGain
                
                for filter in filters {
                    sample = filter.processLeft(sample)
                    if !sample.isFinite || abs(sample) < 1e-10 {
                        sample = 0
                        break
                    }
                }
                
                // 应用 makeup gain 恢复响度
                sample *= makeupGain
            }
            
            // 应用 mastering gain (在混响之前)
            if hasActiveEQ {
                sample *= masteringGain
            }
            
            // Apply reverb if enabled
            if reverbEnabled && reverbDryWetMix > 0.01 {
                sample = applyReverbMono(sample)
            }
            
            // Update RMS for loudness tracking
            let sampleSquared = sample * sample
            rmsLeft = rmsCoeff * rmsLeft + (1.0 - rmsCoeff) * sampleSquared
            
            // Codec-safe ceiling (align with Int16 headroom)
            sample = max(-0.5, min(0.5, sample))
            
            samples[i] = sample
        }
    }
    
    // Process stereo float buffers
    private func processFloatBufferStereo(_ leftSamples: inout [Float], _ rightSamples: inout [Float], count: Int) {
        for i in 0..<count {
            var leftSample = leftSamples[i]
            var rightSample = rightSamples[i]
            
            if !leftSample.isFinite { leftSample = 0 }
            if !rightSample.isFinite { rightSample = 0 }
            
            // Apply input gain
            leftSample *= inputGain
            rightSample *= inputGain
            
            // Pre-limit input to prevent cascading overload
            leftSample = max(-0.9, min(0.9, leftSample))
            rightSample = max(-0.9, min(0.9, rightSample))
            
            // Apply DC offset filter - gentler approach
            // Only remove strong DC component, don't over-correct
            dcFilterLeft = dcFilterCoeff * dcFilterLeft + (1.0 - dcFilterCoeff) * leftSample
            dcFilterRight = dcFilterCoeff * dcFilterRight + (1.0 - dcFilterCoeff) * rightSample
            leftSample = leftSample - dcFilterLeft * 0.5  // Only remove 50% of detected offset
            rightSample = rightSample - dcFilterRight * 0.5
            
            // Apply all filters in series with denormal protection (only if EQ is active)
            if hasActiveEQ {
                // 纯减法 EQ: 先应用全局衰减
                leftSample *= eqCompensationGain
                rightSample *= eqCompensationGain
                
                for filter in filters {
                    leftSample = filter.processLeft(leftSample)
                    rightSample = filter.processRight(rightSample)
                    
                    if !leftSample.isFinite || abs(leftSample) < 1e-10 { leftSample = 0 }
                    if !rightSample.isFinite || abs(rightSample) < 1e-10 { rightSample = 0 }
                }
                
                // 应用 makeup gain 恢复响度
                leftSample *= makeupGain
                rightSample *= makeupGain
            }
            
            // 应用 mastering gain (在混响之前)
            if hasActiveEQ {
                leftSample *= masteringGain
                rightSample *= masteringGain
            }
            
            // Apply reverb if enabled
            if reverbEnabled && reverbDryWetMix > 0.01 {
                leftSample = applyReverbStereo(leftSample, isLeft: true)
                rightSample = applyReverbStereo(rightSample, isLeft: false)
            }
            
            // Update RMS for loudness tracking
            let leftSquared = leftSample * leftSample
            let rightSquared = rightSample * rightSample
            rmsLeft = rmsCoeff * rmsLeft + (1.0 - rmsCoeff) * leftSquared
            rmsRight = rmsCoeff * rmsRight + (1.0 - rmsCoeff) * rightSquared
            
            // Codec-safe ceiling (align with Int16 headroom)
            leftSample = max(-0.5, min(0.5, leftSample))
            rightSample = max(-0.5, min(0.5, rightSample))
            
            leftSamples[i] = leftSample
            rightSamples[i] = rightSample
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
        
        // 安全检查：输入值
        guard input.isFinite else { return 0 }
        
        // Mix range: UI shows 0-100%, actual effect is 0-50% for more pronounced reverb
        let wetMix = reverbDryWetMix / 200.0  // Max 50% wet
        let dryMix = 1.0 - wetMix
        
        // Pre-delay for spatial depth (增加空间感)
        // 安全检查：确保 preDelayIndex 在有效范围内
        guard preDelayIndex >= 0 && preDelayIndex < preDelayBuffer.count else {
            preDelayIndex = 0
            return input
        }
        
        var preDelayedInput = preDelayBuffer[preDelayIndex]
        // 安全检查：预延迟值
        if !preDelayedInput.isFinite {
            preDelayedInput = 0
        }
        
        preDelayBuffer[preDelayIndex] = input
        preDelayIndex = (preDelayIndex + 1) % preDelayTime
        
        // Enhanced feedback scaling (0.75-0.95 range for longer tail)
        let roomScaleFeedback = 0.75 + (reverbRoomSize * 0.2)
        
        // Decay time affects both feedback and damping
        // Longer decay = less damping, more feedback
        let decayScale = min(reverbDecayTime / 10.0, 1.0)
        let enhancedFeedback = min(roomScaleFeedback + (decayScale * 0.1), 0.95)
        let decayDamping = max(0.0, min(1.0 - (decayScale * 0.4), 1.0))
        
        // Process through parallel comb filters (early reflections)
        var combOutput: Float = 0.0
        for i in 0..<combBuffers.count {
            // 安全检查：数组边界
            guard i < combBuffers.count && i < combIndices.count && i < damping.count else {
                continue
            }
            
            let bufferSize = combBuffers[i].count
            guard bufferSize > 0 else { continue }
            
            var readIndex = combIndices[i]
            
            // 安全检查：索引范围
            if readIndex < 0 || readIndex >= bufferSize {
                readIndex = 0
                combIndices[i] = 0
            }
            
            // Read delayed sample
            var delayedSample = combBuffers[i][readIndex]
            
            // 安全检查：延迟样本
            if !delayedSample.isFinite {
                delayedSample = 0
                combBuffers[i][readIndex] = 0
            }
            
            // Apply damping filter (one-pole lowpass) - absorb high frequencies
            let newDamping = delayedSample * (1.0 - dampingCoeff * decayDamping) + damping[i] * dampingCoeff * decayDamping
            
            // 安全检查：damping 值
            if newDamping.isFinite && abs(newDamping) < 100.0 {
                damping[i] = newDamping
                delayedSample = newDamping
            } else {
                damping[i] = 0
                delayedSample = 0
            }
            
            // Feedback with enhanced coefficient for longer tail
            let feedbackSample = preDelayedInput + delayedSample * enhancedFeedback
            
            // 安全检查：反馈值
            if feedbackSample.isFinite && abs(feedbackSample) < 10.0 {
                combBuffers[i][readIndex] = feedbackSample
            } else {
                combBuffers[i][readIndex] = 0
            }
            
            // Accumulate output
            if delayedSample.isFinite {
                combOutput += delayedSample
            }
            
            // Increment index
            combIndices[i] = (readIndex + 1) % bufferSize
        }
        
        // Average the comb outputs
        if combBuffers.count > 0 {
            combOutput /= Float(combBuffers.count)
        }
        
        // 安全检查：combOutput
        if !combOutput.isFinite {
            combOutput = 0
        }
        
        // Process through series allpass filters for diffusion (smoothness)
        var allpassOutput = combOutput
        for i in 0..<allpassBuffers.count {
            // 安全检查：数组边界
            guard i < allpassBuffers.count && i < allpassIndices.count else {
                continue
            }
            
            let bufferSize = allpassBuffers[i].count
            guard bufferSize > 0 else { continue }
            
            var readIndex = allpassIndices[i]
            
            // 安全检查：索引范围
            if readIndex < 0 || readIndex >= bufferSize {
                readIndex = 0
                allpassIndices[i] = 0
            }
            
            var delayedSample = allpassBuffers[i][readIndex]
            
            // 安全检查：延迟样本
            if !delayedSample.isFinite {
                delayedSample = 0
                allpassBuffers[i][readIndex] = 0
            }
            
            let input_ap = allpassOutput
            
            // 安全检查：输入
            if !input_ap.isFinite {
                allpassOutput = 0
                allpassIndices[i] = (readIndex + 1) % bufferSize
                continue
            }
            
            // Allpass formula: output = -input + delayed + (input * feedback)
            let newOutput = -input_ap + delayedSample
            let newBufferValue = input_ap + delayedSample * allpassFeedback
            
            // 安全检查：输出值
            if newOutput.isFinite && abs(newOutput) < 10.0 {
                allpassOutput = newOutput
            } else {
                allpassOutput = 0
            }
            
            // 安全检查：buffer 值
            if newBufferValue.isFinite && abs(newBufferValue) < 10.0 {
                allpassBuffers[i][readIndex] = newBufferValue
            } else {
                allpassBuffers[i][readIndex] = 0
            }
            
            allpassIndices[i] = (readIndex + 1) % bufferSize
        }
        
        // 安全检查：最终 allpass 输出
        if !allpassOutput.isFinite {
            allpassOutput = 0
        }
        
        // Mix dry and wet signals with wet gain for more pronounced reverb effect
        let wetGain = wetMix * 0.7  // Increased to 70% for more noticeable reverb
        let output = input * dryMix + allpassOutput * wetGain
        
        // 安全检查：最终输出
        if !output.isFinite {
            return input
        }
        
        // No additional limiting here - handled in main processing chain
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
        
        // 计算补偿增益（这会更新 eqCompensationGain 和 makeupGain）
        updateEQCompensation()
        
        // 找到最大增益
        var maxGain: Float = 0
        for band in equalizerBands {
            maxGain = max(maxGain, band.gain)
        }
        
        // 更新所有滤波器为纯减法模式
        for i in 0..<filters.count {
            let band = equalizerBands[i]
            let q = max(0.5, min(1.0 / max(band.bandwidth, 1.5), 3.0))
            
            // 关键：滤波器增益 = band.gain - maxGain
            // 这样最高的频段变成 0dB，其他频段都是负值（Cut）
            let filterGainDB = band.gain - maxGain
            
            filters[i].setPeakingEQ(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: q,
                gainDB: filterGainDB  // 永远 <= 0
            )
        }
        
        // Update thread-safe flag
        hasActiveEQ = equalizerBands.contains { abs($0.gain) > 0.1 }
    }
    
    func disableEQ() {
        // 将所有滤波器设置为 0dB (bypass)
        for i in 0..<filters.count {
            let band = equalizerBands[i]
            filters[i].setPeakingEQ(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: 1.0 / band.bandwidth,
                gainDB: 0  // 完全 bypass
            )
        }
        hasActiveEQ = false
        eqCompensationGain = 1.0
        makeupGain = 1.0
        masteringGain = 1.0
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
        eqCompensationGain = 1.0
        makeupGain = 1.0
        masteringGain = 1.0
    }
    
    /// 纯减法 EQ 策略：只做 Cut，不做 Boost
    /// UI 上的 "提升" 实际上是 "减少其他频段的衰减"
    /// 最后用 makeup gain 整体提升恢复响度
    private func updateEQCompensation() {
        // 找到最大的增益值（UI 上的提升）
        var maxGain: Float = 0
        for band in equalizerBands {
            maxGain = max(maxGain, band.gain)
        }
        
        // 如果所有频段都是负增益或0，不需要特殊处理
        if maxGain <= 0 {
            eqCompensationGain = 1.0
            makeupGain = 1.0
            return
        }
        
        // 纯减法策略：
        // 1. 所有频段先降低 -maxGain（让最高的频段变成 0dB）
        // 2. 各频段滤波器设置为相对于 maxGain 的负值
        // 3. 用 makeup gain 恢复整体响度
        
        // eqCompensationGain: 先整体降低 maxGain
        let compensationDB = -maxGain
        eqCompensationGain = pow(10.0, compensationDB / 20.0)
        
        // makeupGain: 恢复大部分响度（95% 恢复，5% 作为安全余量）
        let makeupDB = maxGain * 0.95
        makeupGain = pow(10.0, makeupDB / 20.0)
        
        // 计算 mastering gain 以达到目标响度
        calculateMasteringGain(maxGain: maxGain)
    }
    
    /// 计算 mastering gain 以达到目标响度
    /// 确保无论 EQ 如何调整，最终输出响度保持一致
    private func calculateMasteringGain(maxGain: Float) {
        // 估算 EQ 后的响度损失
        // 纯减法 EQ 会导致整体响度下降
        var averageAttenuation: Float = 0
        for band in equalizerBands {
            // 相对于 maxGain 的衰减
            let relativeGain = band.gain - maxGain
            averageAttenuation += relativeGain
        }
        averageAttenuation /= Float(equalizerBands.count)
        
        // 计算响度补偿
        // averageAttenuation 是负值，表示平均衰减量
        // 我们需要补偿这个损失，但要保守一些
        let loudnessCompensationDB = -averageAttenuation * 0.5
        
        // Mastering gain: 补偿响度 + 提升到目标电平
        // 目标是让输出接近 -14dB LUFS (流媒体标准)
        let masteringBoostDB = loudnessCompensationDB + 2.0  // 额外 2dB 提升
        
        // 限制 mastering gain 范围：最多 +6dB
        let clampedBoostDB = max(0.0, min(masteringBoostDB, 6.0))
        masteringGain = pow(10.0, clampedBoostDB / 20.0)
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
