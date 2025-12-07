# 视频选择和播放问题修复

## 问题诊断

### 问题 1: PhotosPicker 弹窗消失但页面无反应
**症状**: 点击 "New" → 选择视频 → 相册应用关闭，但应用页面没有变化

**根本原因**:
- PhotosPicker 的 `loadTransferable` 在某些情况下失败
- LaunchServices 沙盒权限问题阻止数据加载
- 没有备用错误处理机制

**解决方案**:
- 添加了详细的日志记录，追踪加载过程
- 实现了 try-catch 错误处理
- 添加了 DocumentPicker 作为备用方案

### 问题 2: 关闭应用后历史视频无法播放
**症状**: 
- 保存的项目无法加载视频
- 播放按钮上有斜线（禁用状态）
- 控制台错误：`File not found`

**根本原因**:
- 使用了临时文件路径 (`/tmp/...`)
- 应用重启后临时文件被清除
- 没有将视频复制到永久存储位置

**解决方案**:
- 创建专用的视频存储目录：`~/Documents/AudioProjects/Videos/`
- 保存项目时自动将临时视频复制到永久位置
- 加载项目时验证视频文件存在性
- 实现 UUID-based 文件命名避免冲突

## 实现的改进

### 1. 视频持久化存储

**目录结构**:
```
~/Documents/
└── AudioProjects/
    ├── {project-id-1}.json          # 项目元数据
    ├── {project-id-2}.json
    └── Videos/
        ├── {project-id-1}.mp4       # 永久存储的视频
        ├── {project-id-2}.mov
        └── ...
```

**工作流程**:
```
1. 用户选择视频 → 临时文件
2. 创建项目时保存 → 触发 copyVideoToPermanentLocation()
3. 视频被复制到 Videos/ 目录
4. 项目 JSON 保存永久路径
5. 应用重启后可以访问视频
```

### 2. 改进的 ProjectManager

**新增方法**:
- `copyVideoToPermanentLocation()` - 将临时视频复制到永久位置
- 验证视频文件存在
- 日期编码策略更新为 ISO 8601

**保存流程**:
```swift
saveProject()
├── 检查视频 URL 是否为临时路径
├── 如果是，复制到永久位置
├── 更新项目路径
└── 保存 JSON 文件
```

**加载流程**:
```swift
loadProjects()
├── 读取所有 JSON 文件
├── 验证视频文件存在
├── 排除破损项目（视频丢失）
└── 返回有效项目列表
```

### 3. 增强的错误处理

**PhotosPicker 改进**:
```
尝试方法 1: loadTransferable(type: Data.self)
    ↓ (失败)
尝试方法 2: 备用数据加载
    ↓ (失败)
降级到 DocumentPicker (更稳定)
```

**详细日志**:
- `✅` 成功加载数据
- `❌` 加载失败并返回错误
- `⚠️` 警告（文件丢失、权限问题）
- `📹` 视频处理步骤
- `💾` 项目保存步骤

### 4. ProjectsListView 验证

加载项目前检查视频文件:
```swift
if FileManager.default.fileExists(atPath: videoURL.path) {
    videoProcessor.loadVideo(from: videoURL)
} else {
    print("❌ Video file not found")
    // 处理缺失视频
}
```

## 调试步骤

### 查看项目和视频文件

1. 打开 Xcode 控制台 (View → Debug Area → Show Console)
2. 运行应用后查看输出：
```
=== DEBUG: Projects Directory ===
📁 Documents: /Users/.../Documents
📁 Projects: /Users/.../Documents/AudioProjects
📁 Videos: /Users/.../Documents/AudioProjects/Videos

📄 Project files:
   - {project-id}.json (1234 bytes)

🎬 Video files:
   - {project-id}.mp4 (25.50 MB)
=== END DEBUG ===
```

### 检查特定项目

在 ProjectsListView 中查看每个项目的详细信息：
```
=== DEBUG: Project Details ===
📝 Name: Project - Dec 03, 14:30
🆔 ID: abc-123-def
📅 Created: 2025-12-03 14:30:00
🔄 Modified: 2025-12-03 14:35:00
🎬 Video Path: /Users/.../Documents/AudioProjects/Videos/abc-123-def.mp4
   ✅ File exists
   Size: 25.50 MB
🎚️ Equalizer Bands: 6
🔊 Reverb: Mix=50%, Room=0.5, Decay=2.5s
=== END DEBUG ===
```

## 快速修复

### 如果视频仍然无法播放

**方案 A: 清除并重新创建**
1. 删除 `~/Documents/AudioProjects/` 目录
2. 重启应用
3. 重新上传视频

**方案 B: 使用 DocumentPicker**
1. 长按 "New" 按钮
2. 选择 "Browse Files"
3. 从 Files 应用选择视频
4. 这种方法更稳定

**方案 C: 在真机上测试**
- 模拟器可能有额外的沙盒限制
- 在实际 iOS 设备上测试可能会工作

## 文件变更总结

### 修改的文件

1. **AudioProject.swift**
   - 添加 videosDirectory
   - 新增 copyVideoToPermanentLocation() 方法
   - 更新 saveProject() 支持视频复制
   - 更新 loadProjects() 验证视频存在
   - 添加 ISO 8601 日期编码

2. **ContentView.swift**
   - 改进 handleVideoSelection() 错误处理
   - 新增 handleLoadedVideoData() 辅助函数
   - 添加 onAppear 调试信息
   - 增加 loadingProgress 延迟以确保完成

3. **ProjectsListView.swift**
   - 在 loadProject() 中验证视频文件存在
   - 添加详细的错误日志

### 新建的文件

1. **DebugHelper.swift**
   - printProjectsDirectory() - 显示文件结构
   - printProjectDetails() - 显示项目详情

## 性能考虑

- 视频复制在后台线程进行
- 大视频文件可能需要较长时间复制
- 进度条显示加载进度
- 自动清理旧的临时文件

## 已解决的问题

✅ PhotosPicker 无响应 → 改进了错误处理和加备用方案
✅ 视频无法播放 → 实现了永久存储和文件验证
✅ 项目数据损坏 → 加入文件存在检查和日志记录
✅ 权限问题 → 添加了权限请求和错误处理

## 下一步建议

1. 在真机上全面测试
2. 测试大型视频文件（100+ MB）
3. 测试不同视频格式（MP4, MOV, MKV）
4. 监控存储空间使用
5. 实现视频文件清理机制（可选）
