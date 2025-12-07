//
//  DocumentPickerView.swift
//  Audioo
//
//  Created by Yifan Deng on 2025/12/3.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    var onPickedURL: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .video])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPickedURL: onPickedURL)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPickedURL: (URL) -> Void
        
        init(onPickedURL: @escaping (URL) -> Void) {
            self.onPickedURL = onPickedURL
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            print("✅ DocumentPicker: Selected video at \(url)")
            onPickedURL(url)
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            print("ℹ️ DocumentPicker: Cancelled")
        }
    }
}
