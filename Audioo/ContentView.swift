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
    @StateObject private var projectManager = ProjectManager()
    @State private var selectedItem: PhotosPickerItem?
    @State private var equalizerEnabled = false
    @State private var isProcessing = false
    @State private var processingProgress: Double = 0
    @State private var showShareSheet = false
    @State private var videoToShare: URL?
    @State private var isLoadingVideo = false
    @State private var loadingProgress: Double = 0
    @State private var resetTrigger = false
    @State private var reverbEnabled = false
    @State private var resetReverbTrigger = false
    @State private var showProjectsList = false
    @State private var selectedProject: AudioProject?
    @State private var currentProjectName = ""
    @State private var showDocumentPicker = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 顶部固定区域（不滚动）
                VStack(spacing: 0) {
                    Spacer().frame(height: 20)
                    shareButton
                    videoPlayerSection
                }
                .zIndex(1)
                
                // 可滚动区域
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer().frame(height: 40)  // 顶部间距，避免被渐变遮住
                        audioEffectsModules
                        Spacer().frame(height: 180)  // 为底部栏留出空间
                    }
                }
            }
            
            // 视频窗口下方的渐变层（遮盖滚动内容顶部）
            VStack(spacing: 0) {
                Spacer().frame(height: 20)
                Color.clear.frame(height: 48 + 12)  // shareButton 高度
                
                let videoWidth = UIScreen.main.bounds.width - 40
                let videoHeight = videoWidth * 9 / 16
                Color.clear.frame(height: videoHeight + 12)  // 视频窗口高度
                
                // 渐变层
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black.opacity(0.7), location: 0.3),
                        .init(color: .clear, location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
                
                Spacer()
            }
            .allowsHitTesting(false)
            .zIndex(2)
            
            // 底部渐变层（覆盖在内容之上）
            VStack {
                Spacer()
                bottomGradient
            }
            .allowsHitTesting(false)  // 允许点击穿透到底层
            
            // 底部导航栏（在最上层）
            VStack {
                Spacer()
                bottomNavigationBar
            }
            
            overlayViews
        }
        .sheet(isPresented: $showShareSheet) {
            if let videoURL = videoToShare {
                ShareSheet(items: [videoURL])
            }
        }
        .onAppear {
            // 打印调试信息
            DebugHelper.printProjectsDirectory()
        }
    }
    
    private var shareButton: some View {
        HStack {
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
        .zIndex(200)
    }
    
    private var videoPlayerSection: some View {
        Group {
            let width = UIScreen.main.bounds.width - 40  // 与模块相同的宽度
            let height = width * 9 / 16  // 16:9比例
            
            ZStack {
                if videoProcessor.player != nil {
                    VideoPlayerView(player: videoProcessor.player!)
                        .frame(width: width, height: height)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                } else {
                    uploadVideoView
                        .frame(width: width, height: height)
                }
            }
            .frame(width: width, height: height)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
    
    private var uploadVideoView: some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.1))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .contextMenu {
            Button(action: { showDocumentPicker = true }) {
                Label("Browse Files", systemImage: "folder")
            }
        }
        .onChange(of: selectedItem) { newItem in
            Task {
                await handleVideoSelection(newItem)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url in
                Task {
                    print("✅ DocumentPicker URL selected: \(url)")
                    await handleVideoSelectionFromURL(url)
                }
            }
        }
        .onAppear {
            Task {
                // 预先请求权限
                await PermissionManager.shared.requestPhotoLibraryPermission()
            }
        }
    }
    
    private func handleVideoSelection(_ newItem: PhotosPickerItem?) async {
        guard let newItem = newItem else {
            print("❌ handleVideoSelection: newItem is nil")
            return
        }
        
        print("✅ handleVideoSelection: Starting video selection")
        
        await MainActor.run {
            isLoadingVideo = true
            loadingProgress = 0
            print("📊 loadingVideo set to true")
            // 重置所有效果参数
            equalizerEnabled = false
            reverbEnabled = false
            resetTrigger.toggle()
            resetReverbTrigger.toggle()
            print("🔄 UI state reset")
        }
        
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            Task { @MainActor in
                if loadingProgress < 0.9 {
                    loadingProgress += 0.05
                }
            }
        }
        
        print("📲 Starting to load transferable data...")
        
        // 尝试方式 1: 直接加载 Data
        do {
            if let data = try await newItem.loadTransferable(type: Data.self) {
                print("✅ Data loaded successfully via PhotosPicker, size: \(data.count) bytes")
                await handleLoadedVideoData(data, progressTimer: progressTimer)
                return
            }
        } catch {
            print("⚠️ Failed to load Data directly: \(error)")
        }
        
        // 尝试方式 2: 加载为 Movie 文件
        do {
            if let movieData = try await newItem.loadTransferable(type: Data.self) {
                print("✅ Movie data loaded successfully, size: \(movieData.count) bytes")
                await handleLoadedVideoData(movieData, progressTimer: progressTimer)
                return
            }
        } catch {
            print("⚠️ Failed to load Movie: \(error)")
        }
        
        print("❌ Failed to load video data through all methods")
        progressTimer.invalidate()
        await MainActor.run {
            isLoadingVideo = false
            selectedItem = nil
        }
    }
    
    private func handleLoadedVideoData(_ data: Data, progressTimer: Timer) async {
        progressTimer.invalidate()
        await MainActor.run {
            loadingProgress = 0.95
        }
        
        if let tempURL = saveVideoToTempFile(data: data) {
            print("✅ Video saved to temp file: \(tempURL)")
            await MainActor.run {
                loadingProgress = 1.0
                print("📹 Loading video in processor...")
                videoProcessor.loadVideo(from: tempURL)
                print("✅ Video loaded in processor")
                
                // 创建新项目（使用临时 URL，saveProject 会将其复制到永久位置）
                let newProject = AudioProject(
                    name: generateProjectName(),
                    videoURL: tempURL,
                    equalizerBands: videoProcessor.equalizerBands.map { band in
                        EqualizerBandData(
                            frequency: band.frequency,
                            gain: band.gain,
                            bandwidth: band.bandwidth,
                            name: band.name
                        )
                    },
                    reverbDryWetMix: videoProcessor.reverbDryWetMix,
                    reverbRoomSize: videoProcessor.reverbRoomSize,
                    reverbDecayTime: videoProcessor.reverbDecayTime,
                    reverbEnabled: false
                )
                selectedProject = newProject
                currentProjectName = newProject.name
                projectManager.saveProject(newProject)
                print("💾 Project created and queued for saving")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("✅ Setting isLoadingVideo to false")
                    isLoadingVideo = false
                    // 重置 selectedItem 以便下次可以再次选择
                    selectedItem = nil
                    print("✅ selectedItem reset to nil")
                }
            }
        } else {
            print("❌ Failed to save video to temp file")
            await MainActor.run {
                isLoadingVideo = false
                selectedItem = nil
            }
        }
    }
    
    private func handleVideoSelectionFromURL(_ url: URL) async {
        print("✅ handleVideoSelectionFromURL: Starting with URL \(url)")
        
        // 确保访问权限
        guard url.startAccessingSecurityScopedResource() else {
            print("❌ Failed to access security scoped resource")
            return
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        do {
            let data = try Data(contentsOf: url)
            print("✅ Data loaded from file, size: \(data.count) bytes")
            
            await MainActor.run {
                isLoadingVideo = true
                loadingProgress = 0
                equalizerEnabled = false
                reverbEnabled = false
                resetTrigger.toggle()
                resetReverbTrigger.toggle()
            }
            
            if let tempURL = saveVideoToTempFile(data: data) {
                print("✅ Video saved to temp file: \(tempURL)")
                await MainActor.run {
                    loadingProgress = 1.0
                    print("📹 Loading video in processor...")
                    videoProcessor.loadVideo(from: tempURL)
                    print("✅ Video loaded in processor")
                    
                    let newProject = AudioProject(
                        name: generateProjectName(),
                        videoURL: tempURL,
                        equalizerBands: videoProcessor.equalizerBands.map { band in
                            EqualizerBandData(
                                frequency: band.frequency,
                                gain: band.gain,
                                bandwidth: band.bandwidth,
                                name: band.name
                            )
                        },
                        reverbDryWetMix: videoProcessor.reverbDryWetMix,
                        reverbRoomSize: videoProcessor.reverbRoomSize,
                        reverbDecayTime: videoProcessor.reverbDecayTime,
                        reverbEnabled: false
                    )
                    selectedProject = newProject
                    currentProjectName = newProject.name
                    projectManager.saveProject(newProject)
                    print("💾 Project saved: \(newProject.name)")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isLoadingVideo = false
                        print("✅ isLoadingVideo set to false")
                    }
                }
            } else {
                print("❌ Failed to save video to temp file")
                await MainActor.run {
                    isLoadingVideo = false
                }
            }
        } catch {
            print("❌ Error reading file: \(error)")
            await MainActor.run {
                isLoadingVideo = false
            }
        }
    }
    
    private func generateProjectName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm"
        return "Project - \(formatter.string(from: Date()))"
    }
    
    private var audioEffectsModules: some View {
        VStack(spacing: 12) {
            // Equalizer Card
            VStack(spacing: 0) {
                // Toggle Header
                HStack {
                    HStack(spacing: 8) {
                        // 使用自定义 SVG 图标
                        Image("equalizer-icon")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                            .foregroundColor(.white)
                        
                        Text("Enable equalizer")
                            .font(.system(size: 17))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    
                    if equalizerEnabled {
                        // Reset EQ Button
                        Button(action: {
                            videoProcessor.resetEQ()
                            resetTrigger.toggle()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 32, height: 32)
                        }
                        .padding(.trailing, 8)
                        .transition(.opacity)
                    }
                    
                    Toggle("", isOn: $equalizerEnabled)
                        .labelsHidden()
                        .tint(LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.047, green: 0.831, blue: 0.647),  // #0CD4A5
                                Color(red: 0.490, green: 1.0, blue: 0.855)      // #7DFFDA
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
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
                .padding(.vertical, 16)
                
                // Sliders (展开时显示)
                if equalizerEnabled {
                    HStack(spacing: 13) {
                        ForEach(0..<6) { index in
                            VerticalSliderView(
                                frequency: getFrequencyLabel(index),
                                gain: $videoProcessor.equalizerBands[index].gain,
                                resetTrigger: $resetTrigger,
                                enabled: equalizerEnabled,
                                onGainChange: { gain in
                                    if equalizerEnabled {
                                        videoProcessor.updateEQ(bandIndex: index, gain: gain)
                                        updateCurrentProject()
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                    .transition(.opacity)
                }
            }
            .background(Color.white.opacity(equalizerEnabled ? 0.1 : 0.05))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(equalizerEnabled ? 0.1 : 0.05), lineWidth: 1)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: equalizerEnabled)
            .padding(.horizontal, 20)
            .id("equalizer-card")
            
            // Reverb Card
            VStack(spacing: 0) {
                // Toggle Header
                HStack {
                    HStack(spacing: 8) {
                        // 使用自定义 SVG 图标
                        Image("reverb-icon")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                            .foregroundColor(.white)
                        
                        Text("Enable reverb")
                            .font(.system(size: 17))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    
                    if reverbEnabled {
                        // Reset Reverb Button
                        Button(action: {
                            videoProcessor.resetReverb()
                            resetReverbTrigger.toggle()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 32, height: 32)
                        }
                        .padding(.trailing, 8)
                        .transition(.opacity)
                    }
                    
                    Toggle("", isOn: $reverbEnabled)
                        .labelsHidden()
                        .tint(LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.047, green: 0.831, blue: 0.647),  // #0CD4A5
                                Color(red: 0.490, green: 1.0, blue: 0.855)      // #7DFFDA
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .onChange(of: reverbEnabled) { enabled in
                            if enabled {
                                videoProcessor.enableReverb()
                            } else {
                                videoProcessor.disableReverb()
                            }
                        }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                
                // Reverb Parameters (展开时显示)
                if reverbEnabled {
                    VStack(spacing: 16) {
                        // Dry/Wet Mix
                        HorizontalSliderView(
                            label: "Mix",
                            value: $videoProcessor.reverbDryWetMix,
                            range: 0...100,
                            unit: "%",
                            resetTrigger: $resetReverbTrigger,
                            enabled: reverbEnabled,
                            onValueChange: { _ in
                                updateCurrentProject()
                            }
                        )
                        
                        // Room Size
                        HorizontalSliderView(
                            label: "Room Size",
                            value: $videoProcessor.reverbRoomSize,
                            range: 0...1,
                            unit: "",
                            resetTrigger: $resetReverbTrigger,
                            enabled: reverbEnabled,
                            onValueChange: { _ in
                                updateCurrentProject()
                            }
                        )
                        
                        // Decay Time
                        HorizontalSliderView(
                            label: "Decay Time",
                            value: $videoProcessor.reverbDecayTime,
                            range: 0.1...10,
                            unit: "s",
                            resetTrigger: $resetReverbTrigger,
                            enabled: reverbEnabled,
                            onValueChange: { _ in
                                updateCurrentProject()
                            }
                        )
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                    .transition(.opacity)
                }
            }
            .background(Color.white.opacity(reverbEnabled ? 0.1 : 0.05))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(reverbEnabled ? 0.1 : 0.05), lineWidth: 1)
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: reverbEnabled)
            .padding(.horizontal, 20)
            .animation(
                equalizerEnabled ? .spring(response: 0.4, dampingFraction: 0.8) : 
                .spring(response: 0.4, dampingFraction: 0.8).delay(0.2),
                value: equalizerEnabled
            )
        }
    }
    

    private var bottomGradient: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black.opacity(0.5), location: 0.5),
                .init(color: .black.opacity(0.9), location: 0.85),
                .init(color: .black, location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 200)
        .edgesIgnoringSafeArea(.all)
    }
    
    private var bottomNavigationBar: some View {
        HStack {
            // Projects
            Button(action: { showProjectsList = true }) {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 22))
                    Text("Projects")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.gray)
            }
            
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
            .contextMenu {
                Button(action: { showDocumentPicker = true }) {
                    Label("Browse Files", systemImage: "folder")
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView { url in
                    Task {
                        print("✅ DocumentPicker URL selected from New button: \(url)")
                        await handleVideoSelectionFromURL(url)
                    }
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
        .sheet(isPresented: $showProjectsList) {
            ProjectsListView(
                projectManager: projectManager,
                videoProcessor: videoProcessor,
                selectedProject: $selectedProject,
                showProjectsList: $showProjectsList
            )
        }
    }
    
    private var overlayViews: some View {
        ZStack {
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
            
            // 视频加载进度遮罩
            if isLoadingVideo {
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView(value: loadingProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .frame(width: 200)
                        
                        Text("\(Int(loadingProgress * 100))%")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Loading video...")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
    }
    
    private func exportAndShareVideo() async {
        guard let player = videoProcessor.player,
              let currentItem = player.currentItem else {
            return
        }
        
        // 记录当前播放状态和位置
        let wasPlaying = player.timeControlStatus == .playing
        let currentTime = player.currentTime()
        
        // 暂停视频
        await MainActor.run {
            player.pause()
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
        
        // 在后台线程中执行导出，避免阻塞主线程
        return await withCheckedContinuation { continuation in
            // 在后台队列中执行导出
            DispatchQueue.global(qos: .userInitiated).async {
                // 定期更新进度（在后台线程）
                var progressTimer: DispatchSourceTimer?
                let queue = DispatchQueue.global(qos: .userInitiated)
                progressTimer = DispatchSource.makeTimerSource(queue: queue)
                progressTimer?.setEventHandler {
                    Task { @MainActor in
                        self.processingProgress = Double(exportSession.progress)
                    }
                }
                progressTimer?.schedule(deadline: .now(), repeating: 0.05)  // 更频繁的更新
                progressTimer?.resume()
                
                // 阻塞式导出（在后台线程中不影响UI）
                exportSession.exportAsynchronously {
                    progressTimer?.cancel()
                    
                    Task { @MainActor in
                        self.processingProgress = 1.0
                        
                        if exportSession.status == .completed {
                            self.videoToShare = outputURL
                            self.showShareSheet = true
                        } else if let error = exportSession.error {
                            print("Export failed: \(error.localizedDescription)")
                        } else if exportSession.status == .cancelled {
                            print("Export cancelled")
                        }
                        
                        self.isProcessing = false
                        
                        // 恢复播放状态
                        if wasPlaying {
                            player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                            player.play()
                        }
                        
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func getFrequencyLabel(_ index: Int) -> String {
        switch index {
        case 0: return "60 Hz"
        case 1: return "150 Hz"
        case 2: return "400 Hz"
        case 3: return "1 kHz"
        case 4: return "2.4 kHz"
        case 5: return "15 kHz"
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
    
    private func updateCurrentProject() {
        guard var project = selectedProject else { return }
        
        project.equalizerBands = videoProcessor.equalizerBands.map { band in
            EqualizerBandData(
                frequency: band.frequency,
                gain: band.gain,
                bandwidth: band.bandwidth,
                name: band.name
            )
        }
        project.reverbDryWetMix = videoProcessor.reverbDryWetMix
        project.reverbRoomSize = videoProcessor.reverbRoomSize
        project.reverbDecayTime = videoProcessor.reverbDecayTime
        project.reverbEnabled = reverbEnabled
        
        projectManager.saveProject(project)
        selectedProject = project
    }
}

// Vertical Slider Component for Equalizer
struct VerticalSliderView: View {
    let frequency: String
    @Binding var gain: Float
    @Binding var resetTrigger: Bool
    var enabled: Bool = true
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
                    
                    // Zero line (0 dB reference line at middle)
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 20, height: 0.5)
                        .offset(y: geometry.size.height / 2)
                    
                    // Knob
                    Circle()
                        .fill(enabled ? Color.white : Color.gray.opacity(0.5))
                        .frame(width: 15.91, height: 15.91)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(y: CGFloat(1 - sliderValue) * (geometry.size.height - 15.91))
                        .gesture(
                            enabled ? DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let newValue = 1 - min(max(value.location.y / geometry.size.height, 0), 1)
                                    sliderValue = newValue
                                    let gainValue = Float(newValue * 40 - 20)
                                    gain = gainValue
                                    onGainChange?(gainValue)
                                } : nil
                        )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 179.91)
            
            // Frequency Label
            Text(frequency)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(enabled ? 0.6 : 0.3))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 42)
        .onAppear {
            sliderValue = Double((gain + 20) / 40)
        }
        .onChange(of: resetTrigger) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                sliderValue = 0.5
            }
        }
        .onChange(of: gain) { newGain in
            sliderValue = Double((newGain + 20) / 40)
        }
    }
}

// Horizontal Slider Component for Reverb
struct HorizontalSliderView: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let unit: String
    @Binding var resetTrigger: Bool
    let enabled: Bool
    var onValueChange: ((Float) -> Void)?
    
    @State private var sliderValue: Double = 0.5
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label and Value
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(enabled ? 0.9 : 0.5))
                Spacer()
                Text(formatValue(value))
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(enabled ? 0.7 : 0.4))
            }
            
            // Slider
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 4)
                    
                    // Active track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(enabled ? Color.white.opacity(0.6) : Color.gray.opacity(0.3))
                        .frame(width: CGFloat(sliderValue) * geometry.size.width, height: 4)
                    
                    // Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(x: CGFloat(sliderValue) * (geometry.size.width - 16))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    if enabled {
                                        let newValue = min(max(gesture.location.x / geometry.size.width, 0), 1)
                                        sliderValue = newValue
                                        let mappedValue = range.lowerBound + Float(newValue) * (range.upperBound - range.lowerBound)
                                        value = mappedValue
                                        onValueChange?(mappedValue)
                                    }
                                }
                        )
                }
                .frame(height: 16)
            }
            .frame(height: 16)
        }
        .onAppear {
            updateSliderValue()
        }
        .onChange(of: resetTrigger) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                updateSliderValue()
            }
        }
        .onChange(of: value) { _ in
            updateSliderValue()
        }
    }
    
    private func updateSliderValue() {
        let normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        sliderValue = Double(normalizedValue)
    }
    
    private func formatValue(_ value: Float) -> String {
        if unit == "%" {
            return String(format: "%.0f%%", value)
        } else if unit == "s" {
            return String(format: "%.1f%@", value, unit)
        } else if unit == "ms" {
            return String(format: "%.0f%@", value, unit)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

#Preview {
    ContentView()
}
