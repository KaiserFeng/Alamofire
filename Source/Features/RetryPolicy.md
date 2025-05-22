#  RetryPolicy

## 解读代码，运用了什么设计思想、设计原则、设计模式，实现了什么功能，如何在实际开发中应用

让我从多个角度分析这个重试策略的设计：

1. **设计模式**：
- **策略模式**：通过 `RetryPolicy` 和 `ConnectionLostRetryPolicy` 实现不同的重试策略
- **模板方法**：父类定义重试算法框架，子类实现具体重试逻辑
- **工厂方法**：提供静态方法创建重试策略实例

2. **设计原则**：
```swift
// 单一职责：每个类只负责一种重试策略
open class RetryPolicy: RequestInterceptor {
    // 通用重试逻辑
}

open class ConnectionLostRetryPolicy: RetryPolicy {
    // 专门处理网络连接丢失的重试
}

// 开闭原则：可以通过继承扩展新的重试策略
// 里氏替换：子类可以替换父类使用
```

3. **核心功能**：
```swift
// 1. 指数退避重试
open func retry(_ request: Request, for session: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
    if request.retryCount < retryLimit, shouldRetry(request: request, dueTo: error) {
        let delay = pow(Double(exponentialBackoffBase), Double(request.retryCount)) * exponentialBackoffScale
        completion(.retryWithDelay(delay))
    }
}

// 2. 可重试条件判断
open func shouldRetry(request: Request, dueTo error: Error) -> Bool {
    // 检查 HTTP 方法
    // 检查状态码
    // 检查错误类型
}
```

4. **实际应用示例**：
```swift
// 1. 使用默认重试策略
let session = Session(interceptor: .retryPolicy)

// 2. 自定义重试策略
let retryPolicy = RetryPolicy(
    retryLimit: 3,
    exponentialBackoffBase: 2,
    exponentialBackoffScale: 1.0,
    retryableHTTPMethods: [.get, .post],
    retryableHTTPStatusCodes: [500, 502, 503],
    retryableURLErrorCodes: [.notConnectedToInternet]
)

// 3. 网络连接丢失专用重试
let connectionLostPolicy = ConnectionLostRetryPolicy(
    retryLimit: 5,
    exponentialBackoffBase: 3,
    exponentialBackoffScale: 2.0
)
```

5. **主要优点**：
- 灵活的重试配置
- 支持多种重试策略
- 指数退避避免请求风暴
- 可扩展的错误处理
- 细粒度的重试控制

这个重试策略特别适用于：
- 网络请求重试
- 错误恢复
- 负载均衡
- 服务容错
- 网络波动处理

需要注意的限制：
- 合理配置重试次数
- 避免过度重试
- 考虑请求幂等性
- 注意性能影响

## ConnectionLostRetryPolicy vs RetryPolicy

让我解释 `ConnectionLostRetryPolicy` 和 `RetryPolicy` 的主要区别：

1. **重试范围不同**：
```swift
// RetryPolicy - 支持多种错误类型的重试
class RetryPolicy {
    // 默认支持多种 HTTP 状态码
    public static let defaultRetryableHTTPStatusCodes: Set<Int> = [
        408, // Request Timeout
        500, // Internal Server Error
        502, // Bad Gateway
        503, // Service Unavailable
        504  // Gateway Timeout
    ]
    
    // 默认支持多种 URL 错误
    public static let defaultRetryableURLErrorCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .timedOut,
        .cannotConnectToHost,
        // ... 更多错误类型
    ]
}

// ConnectionLostRetryPolicy - 只处理网络连接丢失
class ConnectionLostRetryPolicy: RetryPolicy {
    init(...) {
        super.init(
            retryableHTTPStatusCodes: [], // 不重试任何 HTTP 状态码
            retryableURLErrorCodes: [.networkConnectionLost] // 只重试网络连接丢失
        )
    }
}
```

2. **使用场景不同**：
```swift
// RetryPolicy - 通用重试策略
let generalRetry = RetryPolicy(
    retryLimit: 3,
    retryableHTTPStatusCodes: [500, 502, 503],
    retryableURLErrorCodes: [.timedOut, .networkConnectionLost]
)

// ConnectionLostRetryPolicy - 专门处理网络连接丢失
let connectionLostRetry = ConnectionLostRetryPolicy(
    retryLimit: 5 // 只关注重试次数等基本配置
)
```

3. **主要特点**：

- `RetryPolicy`：
  - 完整的重试策略
  - 可配置多种重试条件
  - 适用于通用错误处理

- `ConnectionLostRetryPolicy`：
  - 专注于网络连接丢失
  - 配置更简单
  - 更符合特定场景需求

这种设计体现了"专一职责"原则，让重试策略更有针对性和灵活性。

## 上述说设计模式用到了 “里氏替换原则”，说法不正确

从里氏替换原则的角度分析 `ConnectionLostRetryPolicy` 是否可以完全替换 `RetryPolicy`：

**不能完全替换**，原因如下：

1. **功能范围收窄**：
```swift
class RetryPolicy {
    // 支持多种错误类型重试
    let retryableHTTPStatusCodes: Set<Int>
    let retryableURLErrorCodes: Set<URLError.Code>
}

class ConnectionLostRetryPolicy: RetryPolicy {
    // 固定只处理网络连接丢失
    override init(...) {
        super.init(
            retryableHTTPStatusCodes: [], // 强制设为空
            retryableURLErrorCodes: [.networkConnectionLost] // 固定只有这一种
        )
    }
}
```

2. **违反里氏替换原则的地方**：
- RetryPolicy 承诺可以处理多种错误类型
- ConnectionLostRetryPolicy 限制了只处理网络连接丢失
- 如果代码依赖 RetryPolicy 处理其他类型错误，替换后将失效

3. **正确的替换场景**：
```swift
// 只在明确只需要处理网络连接丢失的场景使用
protocol NetworkConnectionRetrier {
    func handleConnectionLost()
}

// 这种场景下可以替换
let retrier: NetworkConnectionRetrier = ConnectionLostRetryPolicy()
```

所以严格来说，这违反了里氏替换原则。子类通过限制功能范围改变了父类的行为承诺。正确的做法应该是：
- 定义更细化的协议
- 根据实际需求选择合适的实现
- 不应强制替换通用重试策略

## 又是如何体现 “模板设计模式” 的呢？

让我解析 `RetryPolicy` 中的模板方法模式实现：

1. **模板方法的核心结构**：
```swift
open class RetryPolicy: RequestInterceptor {
    // 1. 模板方法：定义算法骨架
    open func retry(_ request: Request,
                    for session: Session,
                    dueTo error: Error,
                    completion: @escaping (RetryResult) -> Void) {
        // 固定的算法步骤：
        // 1. 检查重试次数
        // 2. 调用钩子方法判断是否应该重试
        // 3. 计算延迟时间
        if request.retryCount < retryLimit, shouldRetry(request: request, dueTo: error) {
            completion(.retryWithDelay(pow(Double(exponentialBackoffBase), Double(request.retryCount)) * exponentialBackoffScale))
        } else {
            completion(.doNotRetry)
        }
    }

    // 2. 钩子方法：允许子类重写的行为
    open func shouldRetry(request: Request, dueTo error: Error) -> Bool {
        // 默认实现的重试判断逻辑
        guard let httpMethod = request.request?.method, retryableHTTPMethods.contains(httpMethod) else { return false }
        
        // 检查状态码和错误类型
        if let statusCode = request.response?.statusCode, retryableHTTPStatusCodes.contains(statusCode) {
            return true
        } else {
            let errorCode = (error as? URLError)?.code
            let afErrorCode = (error.asAFError?.underlyingError as? URLError)?.code
            guard let code = errorCode ?? afErrorCode else { return false }
            return retryableURLErrorCodes.contains(code)
        }
    }
}
```

2. **子类通过特化实现**：
```swift
open class ConnectionLostRetryPolicy: RetryPolicy {
    // 通过构造函数特化父类行为
    public init(retryLimit: UInt = RetryPolicy.defaultRetryLimit,
                exponentialBackoffBase: UInt = RetryPolicy.defaultExponentialBackoffBase,
                exponentialBackoffScale: Double = RetryPolicy.defaultExponentialBackoffScale,
                retryableHTTPMethods: Set<HTTPMethod> = RetryPolicy.defaultRetryableHTTPMethods) {
        // 特化重试条件
        super.init(retryLimit: retryLimit,
                   exponentialBackoffBase: exponentialBackoffBase,
                   exponentialBackoffScale: exponentialBackoffScale,
                   retryableHTTPMethods: retryableHTTPMethods,
                   retryableHTTPStatusCodes: [], // 特化：不处理HTTP状态码
                   retryableURLErrorCodes: [.networkConnectionLost]) // 特化：只处理网络断开
    }
    
    // 可以选择重写钩子方法
    // override func shouldRetry(request: Request, dueTo error: Error) -> Bool
}
```

模板方法模式的体现：
1. `retry` 方法定义了重试算法的基本框架
2. `shouldRetry` 作为钩子方法允许定制
3. 子类可以通过构造函数或重写钩子方法来特化行为
4. 核心算法流程保持不变，而具体判断逻辑可变

这种设计让重试策略既保持了统一的处理流程，又提供了灵活的定制能力。
