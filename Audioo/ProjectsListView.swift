//
//  ProjectsListView.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/12/3.
//

import SwiftUI

struct ProjectsListView: View {
    @ObservedObject var projectManager: ProjectManager
    @ObservedObject var videoProcessor: VideoProcessor
    @Binding var selectedProject: AudioProject?
    @Binding var showProjectsList: Bool
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 导航栏
                    HStack {
                        Button(action: { showProjectsList = false }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        Text("Projects")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.5))
                    
                    if projectManager.projects.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "folder.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            
                            Text("No Projects")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                            
                            Text("Create your first project by adding a video")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 12) {
                                ForEach(projectManager.projects) { project in
                                    ProjectCard(
                                        project: project,
                                        projectManager: projectManager,
                                        videoProcessor: videoProcessor,
                                        selectedProject: $selectedProject,
                                        showProjectsList: $showProjectsList
                                    )
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct ProjectCard: View {
    let project: AudioProject
    @ObservedObject var projectManager: ProjectManager
    @ObservedObject var videoProcessor: VideoProcessor
    @Binding var selectedProject: AudioProject?
    @Binding var showProjectsList: Bool
    @State private var showDeleteAlert = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Text(formattedDate(project.lastModified))
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    // Edit button
                    Button(action: {
                        loadProject()
                        showProjectsList = false
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                    }
                    
                    // Delete button
                    Button(action: { showDeleteAlert = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .frame(width: 32, height: 32)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
            
            // 参数摘要
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Label("EQ", systemImage: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    
                    Label(project.reverbEnabled ? "Reverb On" : "Reverb Off", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .foregroundColor(project.reverbEnabled ? .green : .gray)
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .alert("Delete Project", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                projectManager.deleteProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this project?")
        }
    }
    
    private func loadProject() {
        // 加载视频和参数
        if let videoURL = project.videoURL {
            // 检查视频文件是否存在
            if FileManager.default.fileExists(atPath: videoURL.path) {
                print("✅ Loading video from: \(videoURL)")
                videoProcessor.loadVideo(from: videoURL)
            } else {
                print("❌ Video file not found at: \(videoURL)")
                // 显示错误或提示用户
            }
        } else {
            print("⚠️ Project has no video URL")
        }
        
        // 恢复均衡器参数
        let equalizerBands = project.equalizerBands.map { bandData in
            EqualizerBand(
                frequency: bandData.frequency,
                gain: bandData.gain,
                bandwidth: bandData.bandwidth,
                name: bandData.name
            )
        }
        videoProcessor.equalizerBands = equalizerBands
        
        // 恢复混响参数
        videoProcessor.reverbDryWetMix = project.reverbDryWetMix
        videoProcessor.reverbRoomSize = project.reverbRoomSize
        videoProcessor.reverbDecayTime = project.reverbDecayTime
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    ProjectsListView(
        projectManager: ProjectManager(),
        videoProcessor: VideoProcessor(),
        selectedProject: .constant(nil),
        showProjectsList: .constant(true)
    )
}
