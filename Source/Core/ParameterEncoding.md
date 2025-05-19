#  ParameterEncoding

让我分析 `ParameterEncoding.swift` 的主要组件：

1. **基础协议定义**:
```swift
public protocol ParameterEncoding: Sendable {
    func encode(_ urlRequest: any URLRequestConvertible, 
                with parameters: Parameters?) throws -> URLRequest
}
```
- 定义参数编码的基本行为
- `Parameters` 是 `[String: Any]` 类型别名

2. **URLEncoding 结构体**:
```swift
public struct URLEncoding: ParameterEncoding {
    // 三种参数编码目标
    enum Destination {
        case methodDependent  // 根据HTTP方法决定
        case queryString     // 作为URL查询参数
        case httpBody       // 作为请求体
    }
    
    // 数组编码方式
    enum ArrayEncoding {
        case brackets        // key[] 方式
        case noBrackets     // 仅 key
        case indexInBrackets // key[0] 方式
        case custom         // 自定义方式
    }
    
    // 布尔值编码方式
    enum BoolEncoding {
        case numeric       // true->1, false->0
        case literal      // true->"true", false->"false"
    }
}
```

3. **JSONEncoding 结构体**:
```swift
public struct JSONEncoding: ParameterEncoding {
    // 将参数序列化为JSON
    public static var `default`: JSONEncoding
    public static var prettyPrinted: JSONEncoding
    
    // 编码实现
    func encode(_ urlRequest: URLRequestConvertible, 
                with parameters: Parameters?) throws -> URLRequest {
        // 设置 Content-Type: application/json
        // 使用 JSONSerialization 序列化参数
    }
}
```

主要功能：
- URL 参数编码
- JSON 参数编码
- 灵活的参数编码配置
- 支持复杂数据结构编码
- 自动设置正确的 Content-Type

这个文件是 Alamofire 参数编码的核心实现，提供了灵活而强大的参数编码功能。

