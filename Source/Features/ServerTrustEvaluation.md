#  ServerTrustEvaluation

## 解读代码，运用了什么设计思想、设计原则、设计模式，实现了什么功能，如何在实际开发中应用

让我分析这个 `ServerTrustEvaluation.swift` 文件的设计：

1. **设计模式**：
```swift
// 策略模式：不同的证书验证策略
protocol ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws
}

// 组合模式：组合多个验证器
class CompositeTrustEvaluator: ServerTrustEvaluating {
    private let evaluators: [any ServerTrustEvaluating]
}

// 工厂模式：创建不同类型的验证器
extension ServerTrustEvaluating {
    public static var publicKeys: PublicKeysTrustEvaluator
    public static var pinnedCertificates: PinnedCertificatesTrustEvaluator
}
```

2. **设计原则**：
```swift
// 单一职责：每个验证器负责一种验证方式
class DefaultTrustEvaluator // 默认验证
class PublicKeysTrustEvaluator // 公钥验证
class PinnedCertificatesTrustEvaluator // 证书验证
class RevocationTrustEvaluator // 证书吊销验证

// 开闭原则：通过协议扩展添加新的验证方式
extension ServerTrustEvaluating {
    public static func composite(evaluators: [any ServerTrustEvaluating])
}
```

3. **核心功能**：
```swift
// 1. 证书验证
let evaluator = PinnedCertificatesTrustEvaluator()
try evaluator.evaluate(serverTrust, forHost: "example.com")

// 2. 公钥验证
let evaluator = PublicKeysTrustEvaluator()
try evaluator.evaluate(serverTrust, forHost: "example.com")

// 3. 证书吊销验证
let evaluator = RevocationTrustEvaluator()
try evaluator.evaluate(serverTrust, forHost: "example.com")
```

4. **实际应用**：
```swift
// 1. HTTPS 请求验证
let manager = ServerTrustManager(evaluators: [
    "api.example.com": DefaultTrustEvaluator(),
    "secure.example.com": PinnedCertificatesTrustEvaluator()
])

// 2. 自签名证书支持
let evaluator = PinnedCertificatesTrustEvaluator(
    certificates: [cert],
    acceptSelfSignedCertificates: true
)

// 3. 组合验证
let evaluator = CompositeTrustEvaluator([
    DefaultTrustEvaluator(),
    PublicKeysTrustEvaluator()
])
```

主要优点：
- 灵活的验证策略
- 类型安全
- 可扩展性好
- 支持自定义验证
- 完整的错误处理

适用场景：
- HTTPS 安全通信
- 证书验证
- 自签名证书处理
- 企业级安全需求

这个设计在处理 HTTPS 安全验证时非常有用。

