//
//  AudioEngineProcessor.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/11/20.
//

import Foundation
import AVFoundation
import Accelerate

class AudioEngineProcessor {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode: AVAudioUnitEQ
    private var audioFile: AVAudioFile?
    
    var bands: [AVAudioUnitEQFilterParameters] {
        return eqNode.bands
    }
    
    init(numberOfBands: Int = 5) {
        eqNode = AVAudioUnitEQ(numberOfBands: numberOfBands)
        setupAudioEngine()
        setupEQBands()
    }
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(eqNode)
        
        // Connect: playerNode -> EQ -> output
        let format = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: eqNode, format: format)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: format)
        
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupEQBands() {
        let frequencies: [Float] = [60, 230, 910, 3600, 14000]
        
        for (index, frequency) in frequencies.enumerated() {
            guard index < eqNode.bands.count else { break }
            let band = eqNode.bands[index]
            band.frequency = frequency
            band.gain = 0
            band.bandwidth = 1.0
            band.filterType = .parametric
            band.bypass = false
        }
        
        eqNode.globalGain = 0
    }
    
    func loadAudioFromVideo(url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let asset = AVAsset(url: url)
        
        // Export audio track to a temporary file
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            completion(.failure(NSError(domain: "AudioEngineProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])))
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let audioURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
        
        exportSession.outputURL = audioURL
        exportSession.outputFileType = .m4a
        
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                switch exportSession.status {
                case .completed:
                    do {
                        self.audioFile = try AVAudioFile(forReading: audioURL)
                        completion(.success(()))
                    } catch {
                        completion(.failure(error))
                    }
                case .failed:
                    completion(.failure(exportSession.error ?? NSError(domain: "AudioEngineProcessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Export failed"])))
                default:
                    completion(.failure(NSError(domain: "AudioEngineProcessor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Export cancelled"])))
                }
            }
        }
    }
    
    func updateBand(index: Int, gain: Float) {
        guard index < eqNode.bands.count else { return }
        eqNode.bands[index].gain = gain
        
        // 自动增益补偿，防止削波
        updateGlobalGain()
    }
    
    /// 计算并应用全局增益补偿，防止 EQ 提升导致削波
    /// 多频段提升时使用更激进的补偿策略
    private func updateGlobalGain() {
        // 计算所有正增益的总和
        var totalPositiveGain: Float = 0
        var positiveCount: Int = 0
        for band in eqNode.bands where !band.bypass {
            if band.gain > 0 {
                totalPositiveGain += band.gain
                positiveCount += 1
            }
        }
        
        // 应用负的全局增益来补偿
        // 非常激进的补偿策略（1.2-1.8 系数范围）
        if totalPositiveGain > 0 {
            // 根据提升频段数量动态调整补偿系数
            // 1个频段: 1.2, 2个频段: 1.5, 3+个频段: 1.8
            var compensationFactor: Float = 1.2
            if positiveCount >= 3 {
                compensationFactor = 1.8  // 极度激进的补偿
            } else if positiveCount == 2 {
                compensationFactor = 1.5  // 很激进的补偿
            }
            
            eqNode.globalGain = -totalPositiveGain * compensationFactor
        } else {
            eqNode.globalGain = 0
        }
    }
    
    func play() {
        guard let audioFile = audioFile else { return }
        
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            
            playerNode.scheduleFile(audioFile, at: nil) {
                // File finished playing
            }
            
            if !playerNode.isPlaying {
                playerNode.play()
            }
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    func pause() {
        playerNode.pause()
    }
    
    func stop() {
        playerNode.stop()
        audioEngine.stop()
    }
    
    func reset() {
        for band in eqNode.bands {
            band.gain = 0
        }
        eqNode.globalGain = 0
    }
}
