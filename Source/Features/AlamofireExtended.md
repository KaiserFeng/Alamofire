#  AlamofireExtended

这是 Alamofire 的扩展机制实现文件 `AlamofireExtended.swift`，它提供了一种优雅的命名空间扩展方式。主要作用是：

1. **扩展命名空间**:
```swift
public struct AlamofireExtension<ExtendedType> {
    public private(set) var type: ExtendedType
}
```
- 提供统一的 `af` 命名空间
- 通过泛型支持任意类型扩展

2. **扩展协议**:
```swift
public protocol AlamofireExtended {
    associatedtype ExtendedType
    static var af: AlamofireExtension<ExtendedType>.Type { get set }
    var af: AlamofireExtension<ExtendedType> { get set }
}
```
- 定义扩展点接口
- 支持实例级和类型级扩展

3. **默认实现**:
```swift
extension AlamofireExtended {
    public static var af: AlamofireExtension<Self>.Type { ... }
    public var af: AlamofireExtension<Self> { ... }
}
```

使用示例：
```swift
// 为 URLRequest 添加扩展
extension URLRequest: AlamofireExtended {}

// 使用扩展
let request = URLRequest(url: url).af.timeoutInterval(30)
```

主要好处：
- 避免命名冲突
- 提供清晰的 API 组织
- 支持链式调用
- 保持原类型整洁

这是 Alamofire 用来组织和扩展功能的核心机制。
