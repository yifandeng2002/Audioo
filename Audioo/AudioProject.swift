//
//  AudioProject.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/12/3.
//

import Foundation

// 项目数据模型
struct AudioProject: Identifiable {
    let id: String
    var name: String
    var videoURLPath: String?  // 存储相对路径而不是URL
    var createdDate: Date
    var lastModified: Date
    
    // 音频效果参数
    var equalizerBands: [EqualizerBandData]
    var reverbDryWetMix: Float
    var reverbRoomSize: Float
    var reverbDecayTime: Float
    var reverbEnabled: Bool
    
    // 计算属性：从路径获取URL
    var videoURL: URL? {
        guard let path = videoURLPath else { return nil }
        return URL(fileURLWithPath: path)
    }
    
    init(
        name: String = "New Project",
        videoURL: URL? = nil,
        equalizerBands: [EqualizerBandData] = [],
        reverbDryWetMix: Float = 0.0,
        reverbRoomSize: Float = 0.5,
        reverbDecayTime: Float = 2.5,
        reverbEnabled: Bool = false
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.videoURLPath = videoURL?.path
        self.createdDate = Date()
        self.lastModified = Date()
        self.equalizerBands = equalizerBands
        self.reverbDryWetMix = reverbDryWetMix
        self.reverbRoomSize = reverbRoomSize
        self.reverbDecayTime = reverbDecayTime
        self.reverbEnabled = reverbEnabled
    }
}

// Codable extension for AudioProject
extension AudioProject: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, videoURLPath, createdDate, lastModified
        case equalizerBands, reverbDryWetMix, reverbRoomSize, reverbDecayTime, reverbEnabled
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(videoURLPath, forKey: .videoURLPath)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(equalizerBands, forKey: .equalizerBands)
        try container.encode(reverbDryWetMix, forKey: .reverbDryWetMix)
        try container.encode(reverbRoomSize, forKey: .reverbRoomSize)
        try container.encode(reverbDecayTime, forKey: .reverbDecayTime)
        try container.encode(reverbEnabled, forKey: .reverbEnabled)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.videoURLPath = try container.decodeIfPresent(String.self, forKey: .videoURLPath)
        self.createdDate = try container.decode(Date.self, forKey: .createdDate)
        self.lastModified = try container.decode(Date.self, forKey: .lastModified)
        self.equalizerBands = try container.decode([EqualizerBandData].self, forKey: .equalizerBands)
        self.reverbDryWetMix = try container.decode(Float.self, forKey: .reverbDryWetMix)
        self.reverbRoomSize = try container.decode(Float.self, forKey: .reverbRoomSize)
        self.reverbDecayTime = try container.decode(Float.self, forKey: .reverbDecayTime)
        self.reverbEnabled = try container.decode(Bool.self, forKey: .reverbEnabled)
    }
}

// 均衡器数据模型
struct EqualizerBandData: Codable {
    var frequency: Float
    var gain: Float
    var bandwidth: Float
    var name: String
}

// 项目管理器
class ProjectManager: ObservableObject {
    @Published var projects: [AudioProject] = []
    private let projectsDirectory: URL
    private let videosDirectory: URL
    
    init() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        self.projectsDirectory = documentsDirectory.appendingPathComponent("AudioProjects")
        self.videosDirectory = documentsDirectory.appendingPathComponent("AudioProjects/Videos")
        
        // 创建项目和视频目录
        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        
        loadProjects()
    }
    
    // 复制视频到永久位置
    func copyVideoToPermanentLocation(from sourceURL: URL, projectID: String) -> URL? {
        let fileExtension = sourceURL.pathExtension
        let destinationURL = videosDirectory.appendingPathComponent("\(projectID).\(fileExtension)")
        
        do {
            // 如果文件已存在，先删除
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            // 复制新文件
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            print("✅ Video copied to permanent location: \(destinationURL)")
            return destinationURL
        } catch {
            print("❌ Failed to copy video: \(error)")
            return nil
        }
    }
    
    func loadProjects() {
        DispatchQueue.global(qos: .background).async {
            do {
                let fileURLs = try FileManager.default.contentsOfDirectory(at: self.projectsDirectory, includingPropertiesForKeys: nil)
                let jsonFiles = fileURLs.filter { $0.pathExtension == "json" }
                
                var loadedProjects: [AudioProject] = []
                for fileURL in jsonFiles {
                    if let data = try? Data(contentsOf: fileURL) {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        if let project = try? decoder.decode(AudioProject.self, from: data) {
                            // 验证视频文件是否存在
                            if let videoPath = project.videoURLPath,
                               FileManager.default.fileExists(atPath: videoPath) {
                                loadedProjects.append(project)
                                print("✅ Loaded project: \(project.name)")
                            } else if project.videoURLPath == nil {
                                loadedProjects.append(project)
                                print("⚠️ Project without video: \(project.name)")
                            } else {
                                print("❌ Video file not found for project: \(project.name)")
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.projects = loadedProjects.sorted { $0.lastModified > $1.lastModified }
                    print("📊 Total projects loaded: \(loadedProjects.count)")
                }
            } catch {
                print("❌ Error loading projects: \(error)")
            }
        }
    }
    
    func saveProject(_ project: AudioProject) {
        DispatchQueue.global(qos: .background).async {
            do {
                var updatedProject = project
                updatedProject.lastModified = Date()
                
                // 如果有视频 URL，复制到永久位置
                if let videoURL = project.videoURL,
                   videoURL.path.contains("tmp") || !FileManager.default.fileExists(atPath: videoURL.path) {
                    print("📹 Video URL is temporary or invalid, copying to permanent location...")
                    if let permanentURL = self.copyVideoToPermanentLocation(from: videoURL, projectID: project.id) {
                        updatedProject.videoURLPath = permanentURL.path
                    }
                }
                
                let projectFile = self.projectsDirectory.appendingPathComponent("\(project.id).json")
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let encoded = try encoder.encode(updatedProject)
                try encoded.write(to: projectFile)
                print("💾 Project saved: \(projectFile)")
                
                DispatchQueue.main.async {
                    if let index = self.projects.firstIndex(where: { $0.id == project.id }) {
                        self.projects[index] = updatedProject
                    } else {
                        self.projects.insert(updatedProject, at: 0)
                    }
                    self.projects.sort { $0.lastModified > $1.lastModified }
                }
            } catch {
                print("❌ Error saving project: \(error)")
            }
        }
    }
    
    func deleteProject(_ project: AudioProject) {
        DispatchQueue.global(qos: .background).async {
            do {
                let projectFile = self.projectsDirectory.appendingPathComponent("\(project.id).json")
                try FileManager.default.removeItem(at: projectFile)
                
                DispatchQueue.main.async {
                    self.projects.removeAll { $0.id == project.id }
                }
            } catch {
                print("Error deleting project: \(error)")
            }
        }
    }
}
