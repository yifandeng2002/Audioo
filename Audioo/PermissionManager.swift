//
//  PermissionManager.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/12/3.
//

import Foundation
import Photos

class PermissionManager {
    static let shared = PermissionManager()
    
    func requestPhotoLibraryPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return granted == .authorized || granted == .limited
        @unknown default:
            return false
        }
    }
}
