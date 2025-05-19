#  ParameterEncoder

让我分析 `ParameterEncoder.swift` 的核心实现和工作原理：

1. **ParameterEncoder 协议**:
```swift
public protocol ParameterEncoder: Sendable {
    func encode<Parameters: Encodable & Sendable>(_ parameters: Parameters?, 
                                                 into request: URLRequest) throws -> URLRequest
}
```
- 定义参数编码的基本协议
- 支持所有遵循 `Encodable` 的类型
- 返回编码后的 `URLRequest`

2. **JSONParameterEncoder**:
```swift
open class JSONParameterEncoder: ParameterEncoder {
    public static var `default`: JSONParameterEncoder
    public static var prettyPrinted: JSONParameterEncoder
    public static var sortedKeys: JSONParameterEncoder
    
    public let encoder: JSONEncoder
    
    // 核心编码逻辑
    open func encode<Parameters: Encodable>(_ parameters: Parameters?,
                                          into request: URLRequest) throws -> URLRequest {
        // 将参数编码为 JSON
        // 设置 Content-Type: application/json
    }
}
```
- JSON 参数编码实现
- 支持多种 JSON 格式化选项
- 自动设置 Content-Type

3. **URLEncodedFormParameterEncoder**:
```swift
open class URLEncodedFormParameterEncoder: ParameterEncoder {
    enum Destination {
        case methodDependent  // 根据 HTTP 方法决定
        case queryString     // 编码到 URL 查询字符串
        case httpBody       // 编码到请求体
    }
    
    // 核心编码逻辑
    open func encode<Parameters: Encodable>(_ parameters: Parameters?,
                                          into request: URLRequest) throws -> URLRequest {
        // 根据 destination 决定编码位置
        // 设置 Content-Type: application/x-www-form-urlencoded
    }
}
```
- URL 编码实现
- 支持灵活的编码目标选择
- 自动处理查询字符串拼接

工作流程：
1. 接收参数和请求
2. 根据编码器类型选择编码策略
3. 执行参数编码
4. 设置适当的 Content-Type
5. 返回编码后的请求

主要特点：
- 类型安全的参数编码
- 支持 JSON 和 URL 编码
- 灵活的编码配置
- 完善的错误处理
- 符合 HTTP 标准的编码行为

这是 Alamofire 参数编码系统的核心实现。

