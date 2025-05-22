#  RequestInterceptor

## 解读代码，运用了什么设计思想、设计原则、设计模式，实现了什么功能，如何在实际开发中应用这个拦截器呢

让我从多个角度分析这个拦截器的设计：

1. **设计模式**：
- **责任链模式**：多个适配器和重试器可以串联处理请求
- **适配器模式**：`RequestAdapter` 用于转换请求
- **策略模式**：可以灵活替换不同的适配和重试策略
- **组合模式**：`Interceptor` 可以组合多个适配器和重试器

2. **设计原则**：
```swift
// 单一职责原则：适配和重试分开
public protocol RequestAdapter { ... }
public protocol RequestRetrier { ... }

// 接口隔离原则：功能接口分离
public protocol RequestInterceptor: RequestAdapter, RequestRetrier {}

// 开闭原则：可以扩展新的适配器和重试器
open class Interceptor: RequestInterceptor {
    public let adapters: [any RequestAdapter]
    public let retriers: [any RequestRetrier]
}
```

3. **核心功能**：
```swift
// 请求适配：修改请求
let tokenAdapter = Adapter { urlRequest, session, completion in
    var request = urlRequest
    request.headers["Authorization"] = "Bearer token"
    completion(.success(request))
}

// 请求重试：处理错误
let retrier = Retrier { request, session, error, completion in
    if error is NetworkError {
        completion(.retryWithDelay(3.0))
    } else {
        completion(.doNotRetry)
    }
}
```

4. **实际应用场景**：
```swift
// 1. 统一添加认证信息
let authInterceptor = Interceptor { urlRequest, _, completion in
    var request = urlRequest
    request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    completion(.success(request))
}

// 2. 请求失败自动刷新token
let tokenInterceptor = Interceptor(
    adaptHandler: { request, _, completion in
        // 添加token
        completion(.success(request))
    },
    retryHandler: { request, session, error, completion in
        if error is TokenExpiredError {
            // 刷新token后重试
            refreshToken { result in
                completion(.retry)
            }
        }
    }
)

// 3. 网络请求配置
let configuration = URLSessionConfiguration.default
let session = Session(
    configuration: configuration,
    interceptor: tokenInterceptor // 添加拦截器
)
```

5. **主要优点**：
- 请求处理逻辑解耦
- 灵活的配置和扩展
- 支持异步操作
- 链式处理请求
- 统一的错误处理

这个拦截器设计优雅且实用，特别适合处理:
- 统一认证
- 请求重试
- 请求转换
- 错误处理
- 日志记录

## 代码如何体现“责任链模式”的？

从代码实现来看，`Interceptor` 确实会遍历所有的适配器和重试器，但遵循了不同的处理策略：

1. **Adapters的处理策略** - 串行处理直到失败：
```swift
private func adapt(_ urlRequest: URLRequest,
                  for session: Session,
                  using adapters: [any RequestAdapter],
                  completion: @escaping @Sendable (Result<URLRequest, any Error>) -> Void) {
    var pendingAdapters = adapters
    
    // 如果没有待处理的适配器，直接返回成功
    guard !pendingAdapters.isEmpty else { 
        completion(.success(urlRequest))
        return 
    }

    let adapter = pendingAdapters.removeFirst()
    
    // 递归处理所有适配器
    adapter.adapt(urlRequest, for: session) { [pendingAdapters] result in
        switch result {
        case let .success(urlRequest):
            // 成功则继续处理下一个适配器
            self.adapt(urlRequest, for: session, using: pendingAdapters, completion: completion)
        case .failure:
            // 失败则直接返回错误，不再处理后续适配器
            completion(result)
        }
    }
}
```

2. **Retriers的处理策略** - 串行处理直到需要重试：
```swift
private func retry(_ request: Request,
                  for session: Session,
                  dueTo error: any Error,
                  using retriers: [any RequestRetrier],
                  completion: @escaping @Sendable (RetryResult) -> Void) {
    var pendingRetriers = retriers
    
    // 如果没有待处理的重试器，返回不重试
    guard !pendingRetriers.isEmpty else { 
        completion(.doNotRetry)
        return 
    }

    let retrier = pendingRetriers.removeFirst()
    
    retrier.retry(request, for: session, dueTo: error) { [pendingRetriers] result in
        switch result {
        case .retry, .retryWithDelay, .doNotRetryWithError:
            // 如果需要重试或有错误，立即返回结果
            completion(result)
        case .doNotRetry:
            // 如果不需要重试，则继续检查下一个重试器
            self.retry(request, for: session, dueTo: error, using: pendingRetriers, completion: completion)
        }
    }
}
```

处理策略的区别：
- Adapters：所有适配器会**顺序执行**，直到**某个失败**或**全部成功**
- Retriers：顺序检查重试器，直到**某个触发重试**或**全部检查完毕**

所以代码实际上是遍历了所有处理器，只是遵循了不同的中断策略。这种设计让处理流程更可控和高效。

