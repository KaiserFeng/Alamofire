# HTTPHeaders

让我分析 `HTTPHeaders.swift` 的核心实现和工作原理：

1. **HTTPHeaders 结构体**:
```swift
public struct HTTPHeaders: Equatable, Hashable, Sendable {
    private var headers: [HTTPHeader] = []
}
```
- 有序、大小写不敏感的 HTTP 头部集合
- 支持序列化和比较操作

2. **HTTPHeader 结构体**:
```swift
public struct HTTPHeader: Equatable, Hashable, Sendable {
    public let name: String
    public let value: String
}
```
- 表示单个 HTTP 头部
- 包含名称和值

3. **主要功能方法**:
```swift
// 增加或更新头部
public mutating func add(name: String, value: String)
public mutating func update(name: String, value: String)

// 删除头部
public mutating func remove(name: String)

// 查找头部值
public func value(for name: String) -> String?

// 排序
public mutating func sort()
```

4. **预定义常用头部**:
```swift
extension HTTPHeader {
    public static func accept(_ value: String) -> HTTPHeader
    public static func authorization(username: String, password: String) -> HTTPHeader
    public static func contentType(_ value: String) -> HTTPHeader
    // ... 更多预定义头部
}
```

5. **默认头部**:
```swift
public static let `default`: HTTPHeaders = [
    .defaultAcceptEncoding,
    .defaultAcceptLanguage,
    .defaultUserAgent
]
```

主要特点：
- 大小写不敏感的头部处理
- 支持头部的增删改查
- 自动去重和更新
- 提供常用头部的便捷方法
- 系统集成（URLRequest, HTTPURLResponse）
- 线程安全（Sendable）

这是 Alamofire 的 HTTP 头部管理系统，提供了完整而灵活的头部处理功能。

## 大小写不敏感的头部处理

从代码实现来看，HTTPHeader 的大小写不敏感特性主要体现在以下几个方面：

1. **名称规范化处理**:
```swift
private func canonicalName(_ name: String) -> String {
    // 将头部名称转换为标准格式
    return name.lowercased()
}
```

2. **值比较逻辑**:
```swift
public static func == (lhs: HTTPHeader, rhs: HTTPHeader) -> Bool {
    // 比较时忽略大小写
    return lhs.name.lowercased() == rhs.name.lowercased() && 
           lhs.value == rhs.value
}
```

3. **查找和更新行为**:
```swift
public func value(for name: String) -> String? {
    // 查找时忽略大小写
    let canonicalName = self.canonicalName(name)
    return headers.first { 
        self.canonicalName($0.name) == canonicalName 
    }?.value
}
```

这样设计的原因：
- 符合 HTTP 规范，HTTP 头部名称本身就是大小写不敏感的
- 避免重复头部（如 "Content-Type" 和 "content-type"）
- 提供更好的开发体验，不需要严格匹配大小写

例如，以下操作结果相同：
```swift
headers.add(name: "Content-Type", value: "application/json")
headers.value(for: "content-type")  // 返回 "application/json"
headers.value(for: "CONTENT-TYPE")  // 返回 "application/json"
```

