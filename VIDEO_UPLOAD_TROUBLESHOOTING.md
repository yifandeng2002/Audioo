# 视频上传问题修复指南

## 问题诊断

应用遇到的错误信息表明 iOS 模拟器的 LaunchServices 沙盒问题，这是系统级别的权限和资源访问问题，而不是应用代码问题。

### 错误日志分析
```
Domain=NSOSStatusErrorDomain Code=-54 "process may not map database"
LaunchServices: store (null) or url (null) was nil
Failed to initialize client context with error
```

这些错误通常出现在：
- iOS 模拟器中使用 PhotosPicker
- 权限未正确请求时
- 沙盒资源访问限制

## 实施的解决方案

### 1. 权限管理器 (`PermissionManager.swift`)
- 显式请求相册访问权限
- 检查权限状态，处理已拒绝和未确定的情况
- 支持异步权限请求

### 2. 替代文件选择器 (`DocumentPickerView.swift`)
- 创建了 UIDocumentPickerViewController 的 SwiftUI 包装
- 允许用户从 Files 应用中选择视频
- 处理安全范围资源访问
- 提供更稳定的文件选择体验

### 3. 增强的日志记录
在 `handleVideoSelection` 函数中添加了详细的调试日志：
- ✅ 成功的操作步骤
- ❌ 失败点
- 📊 进度指示
- 📹 视频加载状态
- 💾 项目保存状态

日志前缀说明：
- `✅` - 成功操作
- `❌` - 错误/失败
- `📊` - 状态更新
- `📹` - 视频处理
- `💾` - 项目保存
- `🔄` - 状态重置
- `ℹ️` - 信息提示

### 4. 双重视频选择方式

#### 方式一：相册选择（PhotosPicker）
- 点击 "New" 按钮直接打开相册
- 选择任何视频文件

#### 方式二：文件浏览（DocumentPicker）
- 长按 "New" 按钮或上传区域（长按相机图标）
- 从上下文菜单选择 "Browse Files"
- 从 Files 应用中选择视频
- 包括从 iCloud Drive、本地存储等位置选择

## 使用说明

### 如果 PhotosPicker 不工作：
1. 长按底部中央的 "New" 按钮
2. 选择 "Browse Files"
3. 在 Files 应用中选择你的视频

### 调试步骤：
1. 打开 Xcode 控制台（底部面板）
2. 观察应用日志，查找 ✅ 或 ❌ 标记
3. 查看完整的加载流程
4. 如果出现 ❌，找到对应的错误消息

### 权限设置：
- 应用会在首次启动时请求相册访问权限
- 如果被拒绝，可以在 iOS 设置中重新授予权限
- 路径：设置 > Audioo > 相册 > 选择 "所有照片" 或 "所选照片"

## 文件列表

**新创建的文件：**
1. `PermissionManager.swift` - 权限管理
2. `DocumentPickerView.swift` - 文件选择器 UI
3. `AudioProject.swift` - 项目数据模型（之前已创建）
4. `ProjectsListView.swift` - 项目列表 UI（之前已创建）

**修改的文件：**
1. `ContentView.swift` - 添加权限请求、DocumentPicker 集成、详细日志

## 故障排除

### 问题：仍然无法看到视频
**解决方案：**
1. 检查 Xcode 控制台日志
2. 尝试使用 DocumentPicker（长按 New）
3. 确认视频格式支持（MP4、MOV 等）
4. 重启模拟器

### 问题：权限被拒绝
**解决方案：**
1. 在 iOS 设置中找到 Audioo
2. 允许访问相册
3. 重新启动应用

### 问题：视频加载缓慢
**解决方案：**
1. 使用较小的视频文件测试
2. 检查设备存储空间
3. 确保网络连接稳定

## 技术细节

### 权限流程
```
onAppear() 
  → requestPhotoLibraryPermission()
    → 检查当前权限状态
    → 如果未确定，请求权限
    → 返回授予的状态
```

### 视频选择流程
```
PhotosPicker/DocumentPicker
  → handleVideoSelection() 或 handleVideoSelectionFromURL()
    → 加载视频数据
    → 保存到临时文件
    → 在 VideoProcessor 中加载
    → 创建项目记录
    → 保存到本地存储
    → 重置 UI 状态
```

## 性能优化

- 视频加载在后台线程执行
- 项目保存使用异步操作
- 进度条实时更新（每 100ms）
- 自动内存管理（使用 defer 清理资源）

## 下一步建议

1. 在真机上测试（iPhone/iPad）
2. 测试不同大小和格式的视频
3. 验证项目列表功能是否正常工作
4. 检查 DocumentPicker 在不同 iOS 版本上的表现
