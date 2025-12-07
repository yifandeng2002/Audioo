//
//  DebugHelper.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/12/3.
//

import Foundation

struct DebugHelper {
    static func printProjectsDirectory() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let projectsDirectory = documentsDirectory.appendingPathComponent("AudioProjects")
        let videosDirectory = projectsDirectory.appendingPathComponent("Videos")
        
        print("\n=== DEBUG: Projects Directory ===")
        print("📁 Documents: \(documentsDirectory.path)")
        print("📁 Projects: \(projectsDirectory.path)")
        print("📁 Videos: \(videosDirectory.path)")
        
        do {
            let projectFiles = try FileManager.default.contentsOfDirectory(atPath: projectsDirectory.path)
            print("\n📄 Project files:")
            for file in projectFiles {
                let fullPath = projectsDirectory.appendingPathComponent(file).path
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                    let fileSize = attributes[.size] as? Int ?? 0
                    print("   - \(file) (\(fileSize) bytes)")
                }
            }
        } catch {
            print("❌ Error reading projects directory: \(error)")
        }
        
        do {
            let videoFiles = try FileManager.default.contentsOfDirectory(atPath: videosDirectory.path)
            print("\n🎬 Video files:")
            for file in videoFiles {
                let fullPath = videosDirectory.appendingPathComponent(file).path
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                    let fileSize = attributes[.size] as? Int ?? 0
                    let fileSizeMB = Double(fileSize) / 1024 / 1024
                    print("   - \(file) (\(String(format: "%.2f", fileSizeMB)) MB)")
                }
            }
        } catch {
            print("❌ Error reading videos directory: \(error)")
        }
        
        print("=== END DEBUG ===\n")
    }
    
    static func printProjectDetails(_ project: AudioProject) {
        print("\n=== DEBUG: Project Details ===")
        print("📝 Name: \(project.name)")
        print("🆔 ID: \(project.id)")
        print("📅 Created: \(project.createdDate)")
        print("🔄 Modified: \(project.lastModified)")
        
        if let videoPath = project.videoURLPath {
            print("🎬 Video Path: \(videoPath)")
            let exists = FileManager.default.fileExists(atPath: videoPath)
            print("   \(exists ? "✅ File exists" : "❌ File missing")")
            if exists {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: videoPath) {
                    let fileSize = attributes[.size] as? Int ?? 0
                    let fileSizeMB = Double(fileSize) / 1024 / 1024
                    print("   Size: \(String(format: "%.2f", fileSizeMB)) MB")
                }
            }
        } else {
            print("🎬 Video Path: nil")
        }
        
        print("🎚️ Equalizer Bands: \(project.equalizerBands.count)")
        print("🔊 Reverb: Mix=\(project.reverbDryWetMix)%, Room=\(project.reverbRoomSize), Decay=\(project.reverbDecayTime)s")
        
        print("=== END DEBUG ===\n")
    }
}
