#  MultipartUpload

## 解读代码，运用了什么设计思想、设计原则、设计模式，实现了什么功能，如何在实际开发中应用

让我分析这个 `MultipartUpload` 类的设计：

1. **设计模式**：
```swift
// 策略模式：根据数据大小选择不同的上传策略
if multipartFormData.contentLength < encodingMemoryThreshold {
    // 小文件策略：直接内存编码
    uploadable = .data(data)
} else {
    // 大文件策略：写入临时文件
    uploadable = .file(fileURL, shouldRemove: true)
}

// 装饰器模式：Protected 包装器保护并发访问
private let multipartFormData: Protected<MultipartFormData>
private let _result = Protected<Result<UploadRequest.Uploadable, any Error>?>(nil)
```

2. **设计原则**：
```swift
// 单一职责：专注于处理 multipart 数据的上传
final class MultipartUpload: @unchecked Sendable {
    // 只负责构建和管理上传过程
}

// 接口隔离：通过协议定义上传行为
extension MultipartUpload: UploadConvertible {
    func asURLRequest() throws -> URLRequest
    func createUploadable() throws -> UploadRequest.Uploadable
}
```

3. **核心功能**：
```swift
// 1. 懒加载结果缓存
var result: Result<UploadRequest.Uploadable, any Error> {
    if let value = _result.read({ $0 }) {
        return value
    }
    let result = Result { try build() }
    _result.write(result)
    return result
}

// 2. 智能的内存管理
func build() throws -> UploadRequest.Uploadable {
    // 根据阈值决定使用内存还是文件系统
    if multipartFormData.contentLength < encodingMemoryThreshold {
        // 小文件用内存
    } else {
        // 大文件用临时文件
    }
}
```

4. **实际应用示例**：
```swift
// 创建上传任务
let formData = MultipartFormData()
formData.append(imageData, withName: "image")

let upload = MultipartUpload(
    encodingMemoryThreshold: 10 * 1024 * 1024, // 10MB
    request: request,
    multipartFormData: formData
)

// 执行上传
let uploadRequest = try upload.createUploadable()
```

主要优点：
- 内存管理优化
- 线程安全设计
- 结果缓存机制
- 灵活的上传策略
- 错误处理完善

适用场景：
- 大文件上传
- 多媒体内容提交
- 复杂表单处理
- 需要内存优化的上传任务

这个设计很好地解决了文件上传时的内存管理和并发安全问题。

