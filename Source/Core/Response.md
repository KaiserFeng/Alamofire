#  Response

Let me analyze the key components of `Response.swift`:

1. **核心类型定义**:
```swift
// 默认响应类型别名
public typealias AFDataResponse<Success> = DataResponse<Success, AFError>
public typealias AFDownloadResponse<Success> = DownloadResponse<Success, AFError>
```

2. **DataResponse 结构体**:
```swift
public struct DataResponse<Success, Failure: Error> {
    public let request: URLRequest?          // 发送的请求
    public let response: HTTPURLResponse?    // 服务器响应
    public let data: Data?                  // 返回的数据
    public let metrics: URLSessionTaskMetrics? // 性能指标
    public let serializationDuration: TimeInterval // 序列化耗时
    public let result: Result<Success, Failure>   // 序列化结果
}
```

3. **DownloadResponse 结构体**:
```swift
public struct DownloadResponse<Success, Failure: Error> {
    // 比 DataResponse 多了以下字段
    public let fileURL: URL?      // 下载文件的最终位置
    public let resumeData: Data?  // 用于断点续传的数据
}
```

4. **转换方法**:
```swift
// 成功结果转换
func map<NewSuccess>(_ transform: (Success) -> NewSuccess)
func tryMap<NewSuccess>(_ transform: (Success) throws -> NewSuccess)

// 错误转换
func mapError<NewFailure: Error>(_ transform: (Failure) -> NewFailure)
func tryMapError<NewFailure: Error>(_ transform: (Failure) throws -> NewFailure)
```

5. **调试支持**:
```swift
// 提供详细的调试信息
extension DataResponse: CustomStringConvertible, CustomDebugStringConvertible {
    // 包含请求、响应、耗时等详细信息
}
```

主要功能：
- 封装网络请求响应
- 支持普通数据和文件下载
- 提供结果转换机制
- 性能指标收集
- 完整的调试信息

这是 Alamofire 响应处理的核心文件。

