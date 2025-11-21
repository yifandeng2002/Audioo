//
//  ContentView.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/11/20.
//

import SwiftUI
import PhotosUI
import AVKit

// ShareSheet for iOS
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @StateObject private var videoProcessor = VideoProcessor()
    @State private var selectedItem: PhotosPickerItem?
    @State private var equalizerEnabled = false
    @State private var isProcessing = false
    @State private var processingProgress: Double = 0
    @State private var showShareSheet = false
    @State private var videoToShare: URL?
    
    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top spacing
                Spacer()
                    .frame(height: 92)
                
                // Title and Share Button
                HStack {
                    Text("IMG_1121")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        if videoProcessor.player != nil {
                            Task {
                                await exportAndShareVideo()
                            }
                        }
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                    .disabled(videoProcessor.player == nil)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                
                // Video Player
                ZStack {
                    if let player = videoProcessor.player {
                        VideoPlayerView(player: player)
                            .frame(height: 234)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    } else {
                        PhotosPicker(selection: $selectedItem, matching: .videos) {
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white.opacity(0.1))
                                        .frame(width: 56, height: 56)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                    Image(systemName: "plus")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                }
                                Text("Upload a Video")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .frame(height: 234)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .onChange(of: selectedItem) { newItem in
                            Task {
                                if let data = try? await newItem?.loadTransferable(type: Data.self),
                                   let tempURL = saveVideoToTempFile(data: data) {
                                    await MainActor.run {
                                        videoProcessor.loadVideo(from: tempURL)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                
                // Equalizer Card
                VStack(spacing: 18) {
                    // Toggle
                    HStack {
                        Text("Enable equalizer")
                            .font(.system(size: 17))
                            .foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $equalizerEnabled)
                            .labelsHidden()
                            .onChange(of: equalizerEnabled) { enabled in
                                if !enabled {
                                    videoProcessor.disableEQ()
                                } else {
                                    // 重新应用当前均衡器设置
                                    for index in 0..<videoProcessor.equalizerBands.count {
                                        videoProcessor.updateEQ(bandIndex: index, gain: videoProcessor.equalizerBands[index].gain)
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 18)
                    
                    // Sliders
                    HStack(alignment: .top, spacing: 8) {
                        // dB Labels
                        VStack(spacing: 62) {
                            Text("+10 dB")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                            Text("0 dB")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                            Text("-10 dB")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .frame(width: 48)
                        
                        // 5 Sliders
                        HStack(spacing: 13) {
                            ForEach(0..<5) { index in
                                VerticalSliderView(
                                    frequency: getFrequencyLabel(index),
                                    gain: $videoProcessor.equalizerBands[index].gain,
                                    onGainChange: { gain in
                                        if equalizerEnabled {
                                            videoProcessor.updateEQ(bandIndex: index, gain: gain)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.trailing, 18)
                    }
                    .padding(.leading, 18)
                }
                .padding(.vertical, 20)
                .background(Color.white.opacity(equalizerEnabled ? 0.1 : 0.05))
                .cornerRadius(24)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(equalizerEnabled ? 0.1 : 0.05), lineWidth: 1)
                )
                .opacity(equalizerEnabled ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.3), value: equalizerEnabled)
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Bottom Navigation
                HStack {
                    // Projects
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 22))
                        Text("Projects")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.gray)
                    
                    Spacer()
                    
                    // New - 打开相册
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 56, height: 56)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                Image(systemName: "plus")
                                    .font(.system(size: 28))
                                    .foregroundColor(.gray)
                            }
                            Text("New")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.gray)
                        }
                    }
                    
                    Spacer()
                    
                    // Settings
                    VStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 22))
                        Text("Settings")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.gray)
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 30)
            }
            
            // 处理进度遮罩
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView(value: processingProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .frame(width: 200)
                        
                        Text("\(Int(processingProgress * 100))%")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Exporting video...")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let videoURL = videoToShare {
                ShareSheet(items: [videoURL])
            }
        }
    }
    
    private func exportAndShareVideo() async {
        guard let player = videoProcessor.player,
              let currentItem = player.currentItem else {
            return
        }
        
        await MainActor.run {
            isProcessing = true
            processingProgress = 0
        }
        
        let asset = currentItem.asset
        
        // 创建导出会话
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            await MainActor.run { isProcessing = false }
            return
        }
        
        // 设置输出路径
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("exported_\(UUID().uuidString).mp4")
        
        // 如果文件已存在,先删除
        try? FileManager.default.removeItem(at: outputURL)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        
        // 如果有音频混合,应用它
        if let audioMix = currentItem.audioMix {
            exportSession.audioMix = audioMix
        }
        
        // 监听进度
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                processingProgress = Double(exportSession.progress)
            }
        }
        
        // 导出
        await exportSession.export()
        timer.invalidate()
        
        await MainActor.run {
            processingProgress = 1.0
            
            if exportSession.status == .completed {
                videoToShare = outputURL
                showShareSheet = true
            } else if let error = exportSession.error {
                print("Export failed: \(error.localizedDescription)")
            }
            
            isProcessing = false
        }
    }
    
    private func getFrequencyLabel(_ index: Int) -> String {
        switch index {
        case 0: return "60 Hz"
        case 1: return "230 Hz"
        case 2: return "910 Hz"
        case 3: return "4 kHz"
        case 4: return "14 kHz"
        default: return ""
        }
    }
    
    private func saveVideoToTempFile(data: Data) -> URL? {
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".mov"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("Error saving video: \(error)")
            return nil
        }
    }
}

// Vertical Slider Component for Equalizer
struct VerticalSliderView: View {
    let frequency: String
    @Binding var gain: Float
    var onGainChange: ((Float) -> Void)?
    
    @State private var sliderValue: Double = 0.5
    
    var body: some View {
        VStack(spacing: 10) {
            // Vertical Slider
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 3.67, height: geometry.size.height)
                    
                    // Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: 15.91, height: 15.91)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(y: CGFloat(1 - sliderValue) * (geometry.size.height - 15.91))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let newValue = 1 - min(max(value.location.y / geometry.size.height, 0), 1)
                                    sliderValue = newValue
                                    let gainValue = Float(newValue * 20 - 10)
                                    gain = gainValue
                                    onGainChange?(gainValue)
                                }
                        )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 179.91)
            
            // Frequency Label
            Text(frequency)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(width: 42)
        .onAppear {
            sliderValue = Double((gain + 10) / 20)
        }
    }
}

#Preview {
    ContentView()
}
