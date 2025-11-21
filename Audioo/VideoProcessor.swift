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
        EqualizerBand(frequency: 230, gain: 0, bandwidth: 1.0, name: "Low Mid"),
        EqualizerBand(frequency: 910, gain: 0, bandwidth: 1.0, name: "Mid"),
        EqualizerBand(frequency: 3600, gain: 0, bandwidth: 1.0, name: "High Mid"),
        EqualizerBand(frequency: 14000, gain: 0, bandwidth: 1.0, name: "Treble")
    ]
    
    private var filters: [MultiChannelBiquadFilter] = []
    private var sampleRate: Float = 44100.0
    private var playerItem: AVPlayerItem?
    private var videoURL: URL?
    private var timeObserver: Any?
    
    init() {
        setupAudioSession()
        setupFilters()
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
    
    private func updateAllFilters() {
        for (index, band) in equalizerBands.enumerated() {
            if index < filters.count {
                filters[index].setPeakingEQ(
                    frequency: band.frequency,
                    sampleRate: sampleRate,
                    q: 1.0 / band.bandwidth,
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
            prepare: { (tap, maxFrames, processingFormat) in },
            unprepare: { tap in },
            process: { (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in
                var timeRange = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
                
                if status != noErr { return }
                
                let clientInfo = MTAudioProcessingTapGetStorage(tap)
                
                let processor = Unmanaged<VideoProcessor>.fromOpaque(clientInfo).takeUnretainedValue()
                processor.applyEQ(to: bufferListInOut, frameCount: numberFrames)
            }
        )
        
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        
        return status == noErr ? tap?.takeUnretainedValue() : nil
    }
    
    private func applyEQ(to bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
        
        // Check if any EQ is active
        let hasActiveEQ = equalizerBands.contains { abs($0.gain) > 0.1 }
        
        // If no EQ is active, just pass through
        if !hasActiveEQ {
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
            
            for i in 0..<count {
                var sample = samples[i]
                
                if !sample.isFinite {
                    sample = 0
                }
                
                // Apply all filters in series
                for filter in filters {
                    sample = filter.processLeft(sample)
                    if !sample.isFinite {
                        sample = 0
                        break
                    }
                }
                
                // Gentle limiting
                sample = max(-0.95, min(0.95, sample))
                samples[i] = sample
            }
        } else if bufferCount >= 2 {
            // Stereo processing
            guard let leftBuffer = audioBufferList[0].mData,
                  let rightBuffer = audioBufferList[1].mData else { return }
            
            let count = Int(audioBufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            let leftSamples = leftBuffer.bindMemory(to: Float.self, capacity: count)
            let rightSamples = rightBuffer.bindMemory(to: Float.self, capacity: count)
            
            for i in 0..<count {
                var leftSample = leftSamples[i]
                var rightSample = rightSamples[i]
                
                if !leftSample.isFinite { leftSample = 0 }
                if !rightSample.isFinite { rightSample = 0 }
                
                // Apply all filters in series
                for filter in filters {
                    leftSample = filter.processLeft(leftSample)
                    rightSample = filter.processRight(rightSample)
                    
                    if !leftSample.isFinite { leftSample = 0 }
                    if !rightSample.isFinite { rightSample = 0 }
                }
                
                // Gentle limiting
                leftSample = max(-0.95, min(0.95, leftSample))
                rightSample = max(-0.95, min(0.95, rightSample))
                
                leftSamples[i] = leftSample
                rightSamples[i] = rightSample
            }
        }
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
        
        // Update the specific filter smoothly
        if bandIndex < filters.count {
            let band = equalizerBands[bandIndex]
            filters[bandIndex].setPeakingEQ(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: 1.0 / band.bandwidth,
                gainDB: gain
            )
        }
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
    
    func reset() {
        for i in 0..<equalizerBands.count {
            updateEQ(bandIndex: i, gain: 0)
        }
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
