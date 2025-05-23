//
//  Request.swift
//
//  Copyright (c) 2014-2024 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// `Request` is the common superclass of all Alamofire request types and provides common state, delegate, and callback
/// handling.
/// Request 是 Alamofire 所有请求类型的基类，提供了请求的基础功能：
/// - 状态管理：控制请求的生命周期状态
/// - 代理处理：处理请求过程中的各种回调
/// - 进度跟踪：上传和下载进度管理
/// - 响应处理：处理请求的响应结果
public class Request: @unchecked Sendable {
    /// State of the `Request`, with managed transitions between states set when calling `resume()`, `suspend()`, or
    /// `cancel()` on the `Request`.
    /// 请求的状态枚举，管理请求的生命周期
    public enum State {
        /// Initial state of the `Request`.
        /// 初始状态：请求刚被创建
        case initialized
        /// `State` set when `resume()` is called. Any tasks created for the `Request` will have `resume()` called on
        /// them in this state.
        /// 继续状态：请求已恢复执行
        case resumed
        /// `State` set when `suspend()` is called. Any tasks created for the `Request` will have `suspend()` called on
        /// them in this state.
        /// 暂停状态：请求被暂停
        case suspended
        /// `State` set when `cancel()` is called. Any tasks created for the `Request` will have `cancel()` called on
        /// them. Unlike `resumed` or `suspended`, once in the `cancelled` state, the `Request` can no longer transition
        /// to any other state.
        /// 取消状态：请求被取消，一旦取消无法恢复
        case cancelled
        /// `State` set when all response serialization completion closures have been cleared on the `Request` and
        /// enqueued on their respective queues.
        /// 完成状态：请求处理完成
        case finished

        /// Determines whether `self` can be transitioned to the provided `State`.
        /// 用于控制 Request 的状态转换是否合法，当前状态是否可以转换到目标状态
        func canTransitionTo(_ state: State) -> Bool {
            switch (self, state) {
                /// 从 初始状态可以转换到任何状态
            case (.initialized, _):
                true
                /// 不能转回初始状态
                /// cancelled 状态不能转换到其他状态
                /// finished 状态不能转换到其他状态
            case (_, .initialized), (.cancelled, _), (.finished, _):
                false
                /// 允许的状态转换
                /// resumed -> cancelled
                /// suspended -> cancelled
                /// resumed -> suspended
                /// suspended -> resumed
            case (.resumed, .cancelled), (.suspended, .cancelled), (.resumed, .suspended), (.suspended, .resumed):
                true
                /// 相同状态间的转换是不允许的
            case (.suspended, .suspended), (.resumed, .resumed):
                false
                /// 任何状态都可以转换到 finished 状态
            case (_, .finished):
                true
            }
        }
    }

    // MARK: - Initial State

    /// `UUID` providing a unique identifier for the `Request`, used in the `Hashable` and `Equatable` conformances.
    /// 请求的唯一标识符，用于区分不同请求
    public let id: UUID
    /// The serial queue for all internal async actions.
    /// 所有内部异步操作的串行队列
    public let underlyingQueue: DispatchQueue
    /// The queue used for all serialization actions. By default it's a serial queue that targets `underlyingQueue`.
    /// 用于序列化操作的队列，默认目标是 underlyingQueue
    public let serializationQueue: DispatchQueue
    /// `EventMonitor` used for event callbacks.
    /// 时间监视器，用于回调请求的各个生命周期事件
    public let eventMonitor: (any EventMonitor)?
    /// The `Request`'s interceptor.
    /// 请求拦截器，用于修改请求或认证处理
    public let interceptor: (any RequestInterceptor)?
    /// The `Request`'s delegate.
    /// 请求代理，处理请求的具体执行
    public private(set) weak var delegate: (any RequestDelegate)?

    // MARK: - Mutable State

    /// Type encapsulating all mutable state that may need to be accessed from anything other than the `underlyingQueue`.
    /// 包含所有需要线程安全访问的可变状态
    struct MutableState {
        /// State of the `Request`.
        /// 请求的当前状态
        var state: State = .initialized
        /// `ProgressHandler` and `DispatchQueue` provided for upload progress callbacks.
        /// 上传进度处理器和对应的队列
        var uploadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)?
        /// `ProgressHandler` and `DispatchQueue` provided for download progress callbacks.
        /// 下载进度处理器和对应的队列
        var downloadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)?
        /// `RedirectHandler` provided for to handle request redirection.
        /// 重定向处理器，处理 HTTP 重定向
        var redirectHandler: (any RedirectHandler)?
        /// `CachedResponseHandler` provided to handle response caching.
        /// 缓存响应处理器，处理响应缓存
        var cachedResponseHandler: (any CachedResponseHandler)?
        /// Queue and closure called when the `Request` is able to create a cURL description of itself.
        /// cURL 命令生成处理器，用于调试目的
        var cURLHandler: (queue: DispatchQueue, handler: @Sendable (String) -> Void)?
        /// Queue and closure called when the `Request` creates a `URLRequest`.
        /// URLRequest 创建处理器
        var urlRequestHandler: (queue: DispatchQueue, handler: @Sendable (URLRequest) -> Void)?
        /// Queue and closure called when the `Request` creates a `URLSessionTask`.
        /// URLSessionTask 创建处理器
        var urlSessionTaskHandler: (queue: DispatchQueue, handler: @Sendable (URLSessionTask) -> Void)?
        /// Response serialization closures that handle response parsing.
        /// 响应序列化器数组，按顺序处理响应
        var responseSerializers: [@Sendable () -> Void] = []
        /// Response serialization completion closures executed once all response serializers are complete.
        /// 响应序列化完成后的回调数组
        var responseSerializerCompletions: [@Sendable () -> Void] = []
        /// Whether response serializer processing is finished.
        /// 标记响应序列化处理是否完成
        var responseSerializerProcessingFinished = false
        /// `URLCredential` used for authentication challenges.
        /// 用于认证挑战的凭证
        var credential: URLCredential?
        /// All `URLRequest`s created by Alamofire on behalf of the `Request`.
        /// 创建的所有 URLRequest
        var requests: [URLRequest] = []
        /// All `URLSessionTask`s created by Alamofire on behalf of the `Request`.
        /// 创建的所有 URLSessionTask
        var tasks: [URLSessionTask] = []
        /// All `URLSessionTaskMetrics` values gathered by Alamofire on behalf of the `Request`. Should correspond
        /// exactly the the `tasks` created.
        /// 收集的所有任务性能指标
        var metrics: [URLSessionTaskMetrics] = []
        /// Number of times any retriers provided retried the `Request`.
        /// 重试次数计数
        var retryCount = 0
        /// Final `AFError` for the `Request`, whether from various internal Alamofire calls or as a result of a `task`.
        /// 最终的错误，可能来自内部调用或任务执行
        var error: AFError?
        /// Whether the instance has had `finish()` called and is running the serializers. Should be replaced with a
        /// representation in the state machine in the future.
        /// 标记请求是否正在结束过程中
        var isFinishing = false
        /// Actions to run when requests are finished. Use for concurrency support.
        /// 请求完成时要执行的操作数组
        var finishHandlers: [() -> Void] = []
    }

    /// Protected `MutableState` value that provides thread-safe access to state values.
    ///
    /// 使用 Protected 包装器确保线程安全的状态访问
    let mutableState = Protected(MutableState())

    /// `State` of the `Request`.
    public var state: State { mutableState.state }
    /// Returns whether `state` is `.initialized`.
    public var isInitialized: Bool { state == .initialized }
    /// Returns whether `state` is `.resumed`.
    public var isResumed: Bool { state == .resumed }
    /// Returns whether `state` is `.suspended`.
    public var isSuspended: Bool { state == .suspended }
    /// Returns whether `state` is `.cancelled`.
    public var isCancelled: Bool { state == .cancelled }
    /// Returns whether `state` is `.finished`.
    public var isFinished: Bool { state == .finished }

    // MARK: Progress

    /// Closure type executed when monitoring the upload or download progress of a request.
    public typealias ProgressHandler = @Sendable (_ progress: Progress) -> Void

    /// `Progress` of the upload of the body of the executed `URLRequest`. Reset to `0` if the `Request` is retried.
    public let uploadProgress = Progress(totalUnitCount: 0)
    /// `Progress` of the download of any response data. Reset to `0` if the `Request` is retried.
    public let downloadProgress = Progress(totalUnitCount: 0)
    /// `ProgressHandler` called when `uploadProgress` is updated, on the provided `DispatchQueue`.
    public internal(set) var uploadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)? {
        get { mutableState.uploadProgressHandler }
        set { mutableState.uploadProgressHandler = newValue }
    }

    /// `ProgressHandler` called when `downloadProgress` is updated, on the provided `DispatchQueue`.
    public internal(set) var downloadProgressHandler: (handler: ProgressHandler, queue: DispatchQueue)? {
        get { mutableState.downloadProgressHandler }
        set { mutableState.downloadProgressHandler = newValue }
    }

    // MARK: Redirect Handling

    /// `RedirectHandler` set on the instance.
    public internal(set) var redirectHandler: (any RedirectHandler)? {
        get { mutableState.redirectHandler }
        set { mutableState.redirectHandler = newValue }
    }

    // MARK: Cached Response Handling

    /// `CachedResponseHandler` set on the instance.
    public internal(set) var cachedResponseHandler: (any CachedResponseHandler)? {
        get { mutableState.cachedResponseHandler }
        set { mutableState.cachedResponseHandler = newValue }
    }

    // MARK: URLCredential

    /// `URLCredential` used for authentication challenges. Created by calling one of the `authenticate` methods.
    public internal(set) var credential: URLCredential? {
        get { mutableState.credential }
        set { mutableState.credential = newValue }
    }

    // MARK: Validators

    /// `Validator` callback closures that store the validation calls enqueued.
    let validators = Protected<[@Sendable () -> Void]>([])

    // MARK: URLRequests

    /// All `URLRequest`s created on behalf of the `Request`, including original and adapted requests.
    public var requests: [URLRequest] { mutableState.requests }
    /// First `URLRequest` created on behalf of the `Request`. May not be the first one actually executed.
    public var firstRequest: URLRequest? { requests.first }
    /// Last `URLRequest` created on behalf of the `Request`.
    public var lastRequest: URLRequest? { requests.last }
    /// Current `URLRequest` created on behalf of the `Request`.
    public var request: URLRequest? { lastRequest }

    /// `URLRequest`s from all of the `URLSessionTask`s executed on behalf of the `Request`. May be different from
    /// `requests` due to `URLSession` manipulation.
    public var performedRequests: [URLRequest] { mutableState.read { $0.tasks.compactMap(\.currentRequest) } }

    // MARK: HTTPURLResponse

    /// `HTTPURLResponse` received from the server, if any. If the `Request` was retried, this is the response of the
    /// last `URLSessionTask`.
    public var response: HTTPURLResponse? { lastTask?.response as? HTTPURLResponse }

    // MARK: Tasks

    /// All `URLSessionTask`s created on behalf of the `Request`.
    public var tasks: [URLSessionTask] { mutableState.tasks }
    /// First `URLSessionTask` created on behalf of the `Request`.
    public var firstTask: URLSessionTask? { tasks.first }
    /// Last `URLSessionTask` created on behalf of the `Request`.
    public var lastTask: URLSessionTask? { tasks.last }
    /// Current `URLSessionTask` created on behalf of the `Request`.
    public var task: URLSessionTask? { lastTask }

    // MARK: Metrics

    /// All `URLSessionTaskMetrics` gathered on behalf of the `Request`. Should correspond to the `tasks` created.
    public var allMetrics: [URLSessionTaskMetrics] { mutableState.metrics }
    /// First `URLSessionTaskMetrics` gathered on behalf of the `Request`.
    public var firstMetrics: URLSessionTaskMetrics? { allMetrics.first }
    /// Last `URLSessionTaskMetrics` gathered on behalf of the `Request`.
    public var lastMetrics: URLSessionTaskMetrics? { allMetrics.last }
    /// Current `URLSessionTaskMetrics` gathered on behalf of the `Request`.
    public var metrics: URLSessionTaskMetrics? { lastMetrics }

    // MARK: Retry Count

    /// Number of times the `Request` has been retried.
    public var retryCount: Int { mutableState.retryCount }

    // MARK: Error

    /// `Error` returned from Alamofire internally, from the network request directly, or any validators executed.
    public internal(set) var error: AFError? {
        get { mutableState.error }
        set { mutableState.error = newValue }
    }

    /// Default initializer for the `Request` superclass.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`.
    init(id: UUID = UUID(),
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: (any EventMonitor)?,
         interceptor: (any RequestInterceptor)?,
         delegate: any RequestDelegate) {
        self.id = id
        self.underlyingQueue = underlyingQueue
        self.serializationQueue = serializationQueue
        self.eventMonitor = eventMonitor
        self.interceptor = interceptor
        self.delegate = delegate
    }

    // MARK: - Internal Event API

    // All API must be called from underlyingQueue.
    /// 所有的内部事件的处理必须在 underlyingQueue 队列上执行
    /// 这确保了事件处理的线程安全性

    /// Called when an initial `URLRequest` has been created on behalf of the instance. If a `RequestAdapter` is active,
    /// the `URLRequest` will be adapted before being issued.
    /// 当初始 URLRequest 被创建时调用
    ///
    /// - Parameter request: The `URLRequest` created.  创建的 URLRequest
    func didCreateInitialURLRequest(_ request: URLRequest) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 保存请求记录
        mutableState.write { $0.requests.append(request) }

        /// 通知事件监听器
        eventMonitor?.request(self, didCreateInitialURLRequest: request)
    }

    /// Called when initial `URLRequest` creation has failed, typically through a `URLRequestConvertible`.
    /// 当 URLRequest 创建失败时调用，通常是由于 URLRequestConvertible 转换失败
    ///
    /// - Note: Triggers retry.
    /// 会触发重试机制
    ///
    /// - Parameter error: `AFError` thrown from the failed creation.   产生的错误
    func didFailToCreateURLRequest(with error: AFError) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 保存错误
        self.error = error

        /// 通知事件监听器
        eventMonitor?.request(self, didFailToCreateURLRequestWithError: error)

        /// 主要用于处理 cURL 命令的生成和回调, 开发调试用的
        callCURLHandlerIfNecessary()

        /// 尝试重试或结束请求
        retryOrFinish(error: error)
    }

    /// Called when a `RequestAdapter` has successfully adapted a `URLRequest`.
    /// 适配器成功修改请求后调用
    ///
    /// - Parameters:
    ///   - initialRequest: The `URLRequest` that was adapted.  原始请求
    ///   - adaptedRequest: The `URLRequest` returned by the `RequestAdapter`.  适配后的请求
    func didAdaptInitialRequest(_ initialRequest: URLRequest, to adaptedRequest: URLRequest) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 保存适配后的请求
        mutableState.write { $0.requests.append(adaptedRequest) }

        /// 通知事件监听器
        eventMonitor?.request(self, didAdaptInitialRequest: initialRequest, to: adaptedRequest)
    }

    /// Called when a `RequestAdapter` fails to adapt a `URLRequest`.
    /// 适配器修改请求失败时调用
    ///
    /// - Note: Triggers retry.
    ///
    /// - Parameters:
    ///   - request: The `URLRequest` the adapter was called with.  待适配的请求
    ///   - error:   The `AFError` returned by the `RequestAdapter`.    适配失败的错误
    func didFailToAdaptURLRequest(_ request: URLRequest, withError error: AFError) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        self.error = error

        eventMonitor?.request(self, didFailToAdaptURLRequest: request, withError: error)

        callCURLHandlerIfNecessary()

        retryOrFinish(error: error)
    }

    /// Final `URLRequest` has been created for the instance.
    /// 最终 URLRequest 创建完成时调用
    ///
    /// - Parameter request: The `URLRequest` created.  最终的 URLRequest
    func didCreateURLRequest(_ request: URLRequest) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 执行 URLRequest 处理回调
        mutableState.read { state in
            guard let urlRequestHandler = state.urlRequestHandler else { return }

            urlRequestHandler.queue.async { urlRequestHandler.handler(request) }
        }

        /// 通知事件监听器
        eventMonitor?.request(self, didCreateURLRequest: request)

        /// 生成调试信息
        callCURLHandlerIfNecessary()
    }

    /// Asynchronously calls any stored `cURLHandler` and then removes it from `mutableState`.
    /// 开发调试、问题诊断（开发辅助功能）
    private func callCURLHandlerIfNecessary() {
        mutableState.write { mutableState in
            /// 1、检查是否存在 cURLHandler
            guard let cURLHandler = mutableState.cURLHandler else { return }
            
            /// 2、在指定队列上异步执行回调
            cURLHandler.queue.async { cURLHandler.handler(self.cURLDescription()) }

            /// 3、清除 handler
            mutableState.cURLHandler = nil
        }
    }

    /// Called when a `URLSessionTask` is created on behalf of the instance.
    /// 当 URLSessionTask 被创建时调用
    ///
    /// - Parameter task: The `URLSessionTask` created. 创建的任务对象
    func didCreateTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { state in
            /// 将创建的任务添加到任务列表
            state.tasks.append(task)

            /// 如果存在任务创建回调，则执行
            guard let urlSessionTaskHandler = state.urlSessionTaskHandler else { return }

            urlSessionTaskHandler.queue.async { urlSessionTaskHandler.handler(task) }
        }

        /// 通知事件监听器
        eventMonitor?.request(self, didCreateTask: task)
    }

    /// Called when resumption is completed.
    /// 请求恢复完成时调用
    func didResume() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.requestDidResume(self)
    }

    /// Called when a `URLSessionTask` is resumed on behalf of the instance.
    /// 当 URLSessionTask 恢复时调用
    ///
    /// - Parameter task: The `URLSessionTask` resumed. 被恢复的任务
    func didResumeTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.request(self, didResumeTask: task)
    }

    /// Called when suspension is completed.
    /// 请求挂起完成时调用
    func didSuspend() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.requestDidSuspend(self)
    }

    /// Called when a `URLSessionTask` is suspended on behalf of the instance.
    /// 当 URLSessionTask 挂起时调用
    ///
    /// - Parameter task: The `URLSessionTask` suspended.   被挂起的任务
    func didSuspendTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.request(self, didSuspendTask: task)
    }

    /// Called when cancellation is completed, sets `error` to `AFError.explicitlyCancelled`.
    /// 请求取消完成时调用
    func didCancel() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        mutableState.write { mutableState in
            /// 如果没有其他错误，则设置为显式取消错误
            mutableState.error = mutableState.error ?? AFError.explicitlyCancelled
        }

        eventMonitor?.requestDidCancel(self)
    }

    /// Called when a `URLSessionTask` is cancelled on behalf of the instance.
    /// 当 URLSessionTask 取消时调用
    ///
    /// - Parameter task: The `URLSessionTask` cancelled.   被取消的任务
    func didCancelTask(_ task: URLSessionTask) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        eventMonitor?.request(self, didCancelTask: task)
    }

    /// Called when a `URLSessionTaskMetrics` value is gathered on behalf of the instance.
    /// 当收集到任务性能指标时调用
    ///
    /// - Parameter metrics: The `URLSessionTaskMetrics` gathered.  收集到的任务指标数据
    func didGatherMetrics(_ metrics: URLSessionTaskMetrics) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 保存性能指标
        mutableState.write { $0.metrics.append(metrics) }

        /// 通知事件监听器
        eventMonitor?.request(self, didGatherMetrics: metrics)
    }

    /// Called when a `URLSessionTask` fails before it is finished, typically during certificate pinning.
    /// 当任务在完成之前失败时调用，通常发生在证书验证期间
    ///
    /// - Parameters:
    ///   - task:  The `URLSessionTask` which failed.   失败的任务
    ///   - error: The early failure `AFError`.     提前失败的错误
    func didFailTask(_ task: URLSessionTask, earlyWithError error: AFError) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        self.error = error

        // Task will still complete, so didCompleteTask(_:with:) will handle retry.
        /// 任务仍会完成，所以让 didCompleteTask(_:with:) 处理重试
        eventMonitor?.request(self, didFailTask: task, earlyWithError: error)
    }

    /// Called when a `URLSessionTask` completes. All tasks will eventually call this method.
    /// 当任务完成时调用，所有任务最终都会调用这个方法
    ///
    /// - Note: Response validation is synchronously triggered in this step.
    ///
    /// - Parameters:
    ///   - task:  The `URLSessionTask` which completed.    完成的 URLSessionTask
    ///   - error: The `AFError` `task` may have completed with. If `error` has already been set on the instance, this
    ///            value is ignored.    任务可能产生的错误，如果 error 已经被设置，则忽略
    func didCompleteTask(_ task: URLSessionTask, with error: AFError?) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 保存错误
        self.error = self.error ?? error

        /// 执行所有验证器
        let validators = validators.read { $0 }
        validators.forEach { $0() }

        /// 通知事件监听器
        eventMonitor?.request(self, didCompleteTask: task, with: error)

        /// 根据错误决定是重试还是结束请求
        retryOrFinish(error: self.error)
    }

    /// Called when the `RequestDelegate` is going to retry this `Request`. Calls `reset()`.
    /// 在 RequestDelegate 准备重试此请求时调用
    /// 重置请求状态，准备重试
    func prepareForRetry() {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 增加重试计数
        mutableState.write { $0.retryCount += 1 }

        /// 重置请求状态
        reset()

        /// 通知事件监听器
        eventMonitor?.requestIsRetrying(self)
    }

    /// Called to determine whether retry will be triggered for the particular error, or whether the instance should
    /// call `finish()`.
    /// 根据错误决定是重试还是结束请求
    ///
    /// - Parameter error: The possible `AFError` which may trigger retry.  可能触发重试的错误
    func retryOrFinish(error: AFError?) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 如果请求已取消或者没有错误或没有代理，直接结束
        guard !isCancelled, let error, let delegate else { finish(); return }

        /// 询问代理是否需要重试
        delegate.retryResult(for: self, dueTo: error) { retryResult in
            switch retryResult {
            case .doNotRetry:
                /// 不重试，直接结束
                self.finish()
            case let .doNotRetryWithError(retryError):
                /// 使用新的错误结束请求
                self.finish(error: retryError.asAFError(orFailWith: "Received retryError was not already AFError"))
            case .retry, .retryWithDelay:
                /// 重试请求，可能带有延迟
                delegate.retryRequest(self, withDelay: retryResult.delay)
            }
        }
    }

    /// Finishes this `Request` and starts the response serializers.
    /// 结束请求并开始响应序列化过程
    ///
    /// - Parameter error: The possible `Error` with which the instance will finish.    可能的错误
    func finish(error: AFError? = nil) {
        dispatchPrecondition(condition: .onQueue(underlyingQueue))

        /// 防止重复调用 finish
        guard !mutableState.isFinishing else { return }

        mutableState.isFinishing = true

        if let error { self.error = error }

        // Start response handlers
        /// 开始响应处理
        processNextResponseSerializer()

        /// 通知事件监听器
        eventMonitor?.requestDidFinish(self)
    }

    /// Appends the response serialization closure to the instance.
    /// 添加响应序列化闭包到处理队列
    ///
    ///  - Note: This method will also `resume` the instance if `delegate.startImmediately` returns `true`.
    ///  如果 delegate.startImmediately 返回 true，则会自动恢复请求
    ///
    /// - Parameter closure: The closure containing the response serialization call.
    func appendResponseSerializer(_ closure: @escaping @Sendable () -> Void) {
        mutableState.write { mutableState in
            /// 添加 序列化器到队列
            mutableState.responseSerializers.append(closure)

            /// 如果请求已完成，重置状态为继续
            if mutableState.state == .finished {
                mutableState.state = .resumed
            }

            /// 如果序列化处理已完成，处理下一个
            if mutableState.responseSerializerProcessingFinished {
                underlyingQueue.async { self.processNextResponseSerializer() }
            }

            /// 如果可以转换到继续状态，且代理允许立即开始，则恢复请求
            if mutableState.state.canTransitionTo(.resumed) {
                underlyingQueue.async { if self.delegate?.startImmediately == true { self.resume() } }
            }
        }
    }

    /// Returns the next response serializer closure to execute if there's one left.
    /// 获取下一个要执行的响应序列化闭包
    ///
    /// - Returns: The next response serialization closure, if there is one.    下一个响应序列化闭包，如果有的话
    func nextResponseSerializer() -> (@Sendable () -> Void)? {
        var responseSerializer: (@Sendable () -> Void)?

        mutableState.write { mutableState in
            let responseSerializerIndex = mutableState.responseSerializerCompletions.count

            if responseSerializerIndex < mutableState.responseSerializers.count {
                responseSerializer = mutableState.responseSerializers[responseSerializerIndex]
            }
        }

        return responseSerializer
    }

    /// Processes the next response serializer and calls all completions if response serialization is complete.
    /// 处理下一个响应序列化器，如果所有序列化完成则调用所有完成回调
    func processNextResponseSerializer() {
        guard let responseSerializer = nextResponseSerializer() else {
            // Execute all response serializer completions and clear them
            /// 所有序列化器处理完成，执行完成回调
            var completions: [@Sendable () -> Void] = []

            mutableState.write { mutableState in
                completions = mutableState.responseSerializerCompletions

                // Clear out all response serializers and response serializer completions in mutable state since the
                // request is complete. It's important to do this prior to calling the completion closures in case
                // the completions call back into the request triggering a re-processing of the response serializers.
                // An example of how this can happen is by calling cancel inside a response completion closure.
                /// 清除所有序列化器和完成回调
                /// 在调用完成闭包之前执行清理很重要，因为完成闭包可能会触发重新处理
                mutableState.responseSerializers.removeAll()
                mutableState.responseSerializerCompletions.removeAll()

                /// 如果可以转换到完成状态，则更新状态
                if mutableState.state.canTransitionTo(.finished) {
                    mutableState.state = .finished
                }

                mutableState.responseSerializerProcessingFinished = true
                mutableState.isFinishing = false
            }

            /// 执行所有完成回调
            completions.forEach { $0() }

            // Cleanup the request
            /// 清理请求
            cleanup()

            return
        }

        /// 在序列化队列上异步执行序列化器
        serializationQueue.async { responseSerializer() }
    }

    /// Notifies the `Request` that the response serializer is complete.
    /// 通知请求响应序列化器已完成
    ///
    /// - Parameter completion: The completion handler provided with the response serializer, called when all serializers
    ///                         are complete.
    ///                         响应序列化器提供的完成处理器，在所有序列化器完成时调用
    func responseSerializerDidComplete(completion: @escaping @Sendable () -> Void) {
        mutableState.write { $0.responseSerializerCompletions.append(completion) }
        processNextResponseSerializer()
    }

    /// Resets all task and response serializer related state for retry.
    /// 重置请求的所有任务和序列化相关状态，为重试做准备
    func reset() {
        /// 清除错误状态
        error = nil

        /// 重置上传和下载进度
        uploadProgress.totalUnitCount = 0
        uploadProgress.completedUnitCount = 0
        downloadProgress.totalUnitCount = 0
        downloadProgress.completedUnitCount = 0

        /// 重置内部状态
        mutableState.write { state in
            state.isFinishing = false
            state.responseSerializerCompletions = []
        }
    }

    /// Called when updating the upload progress.
    /// 更新上传进度并触发进度回调
    ///
    /// - Parameters:
    ///   - totalBytesSent: Total bytes sent so far.    已发送的总字节数
    ///   - totalBytesExpectedToSend: Total bytes expected to send.     预期要发送的总字节数
    func updateUploadProgress(totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        uploadProgress.totalUnitCount = totalBytesExpectedToSend
        uploadProgress.completedUnitCount = totalBytesSent

        /// 在指定队列上异步执行进度回调
        uploadProgressHandler?.queue.async { self.uploadProgressHandler?.handler(self.uploadProgress) }
    }

    /// Perform a closure on the current `state` while locked.
    /// 在加锁的情况下访问当前状态
    ///
    /// - Parameter perform: The closure to perform.    要执行的闭包
    func withState(perform: (State) -> Void) {
        mutableState.withState(perform: perform)
    }

    // MARK: Task Creation

    /// Called when creating a `URLSessionTask` for this `Request`. Subclasses must override.
    /// 创建 URLSessionTask 的方法，子类必须重写
    ///
    /// - Parameters:
    ///   - request: `URLRequest` to use to create the `URLSessionTask`.    当前 URLRequest
    ///   - session: `URLSession` which creates the `URLSessionTask`.       当前 URLSession
    ///
    /// - Returns:   The `URLSessionTask` created.      创建的 URLSessionTask
    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        fatalError("Subclasses must override.")
    }

    // MARK: - Public API

    // These APIs are callable from any queue.

    // MARK: State

    /// Cancels the instance. Once cancelled, a `Request` can no longer be resumed or suspended.
    /// 取消请求。一旦取消，请求将不能再被恢复或挂起
    ///
    /// - Returns: The instance.    请求实例本身，支持链式调用
    @discardableResult
    public func cancel() -> Self {
        mutableState.write { mutableState in
            /// 如果当前状态可以转换到取消状态，则执行取消操作
            guard mutableState.state.canTransitionTo(.cancelled) else { return }

            mutableState.state = .cancelled

            /// 通知取消事件
            underlyingQueue.async { self.didCancel() }

            /// 如果任务已完成，直接结束
            guard let task = mutableState.tasks.last, task.state != .completed else {
                underlyingQueue.async { self.finish() }
                return
            }

            // Resume to ensure metrics are gathered.
            /// 恢复任务以确保收集指标
            task.resume()
            task.cancel()
            underlyingQueue.async { self.didCancelTask(task) }
        }

        return self
    }

    /// Suspends the instance.
    /// 暂停请求
    ///
    /// - Returns: The instance.    支持链式调用
    @discardableResult
    public func suspend() -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.suspended) else { return }

            mutableState.state = .suspended

            underlyingQueue.async { self.didSuspend() }

            guard let task = mutableState.tasks.last, task.state != .completed else { return }

            task.suspend()
            underlyingQueue.async { self.didSuspendTask(task) }
        }

        return self
    }

    /// Resumes the instance.
    /// 恢复请求
    ///
    /// - Returns: The instance.
    @discardableResult
    public func resume() -> Self {
        mutableState.write { mutableState in
            guard mutableState.state.canTransitionTo(.resumed) else { return }

            mutableState.state = .resumed

            underlyingQueue.async { self.didResume() }

            guard let task = mutableState.tasks.last, task.state != .completed else { return }

            task.resume()
            underlyingQueue.async { self.didResumeTask(task) }
        }

        return self
    }

    // MARK: - Closure API

    /// Associates a credential using the provided values with the instance.
    /// 认证处理
    /// 使用用户名和密码设置认证凭证
    ///
    /// - Parameters:
    ///   - username:    The username.
    ///   - password:    The password.
    ///   - persistence: The `URLCredential.Persistence` for the created `URLCredential`. `.forSession` by default. 凭证持久化级别
    ///
    /// - Returns:       The instance.  支持链式调用
    @discardableResult
    public func authenticate(username: String, password: String, persistence: URLCredential.Persistence = .forSession) -> Self {
        let credential = URLCredential(user: username, password: password, persistence: persistence)

        return authenticate(with: credential)
    }

    /// Associates the provided credential with the instance.
    /// 使用已有的凭证进行认证
    ///
    /// - Parameter credential: The `URLCredential`.
    ///
    /// - Returns:              The instance.
    @discardableResult
    public func authenticate(with credential: URLCredential) -> Self {
        mutableState.credential = credential

        return self
    }

    /// Sets a closure to be called periodically during the lifecycle of the instance as data is read from the server.
    ///
    /// - Note: Only the last closure provided is used.
    ///
    /// - Parameters:
    ///   - queue:   The `DispatchQueue` to execute the closure on. `.main` by default.
    ///   - closure: The closure to be executed periodically as data is read from the server.
    ///
    /// - Returns:   The instance.
    @preconcurrency
    @discardableResult
    public func downloadProgress(queue: DispatchQueue = .main, closure: @escaping ProgressHandler) -> Self {
        mutableState.downloadProgressHandler = (handler: closure, queue: queue)

        return self
    }

    /// Sets a closure to be called periodically during the lifecycle of the instance as data is sent to the server.
    ///
    /// - Note: Only the last closure provided is used.
    ///
    /// - Parameters:
    ///   - queue:   The `DispatchQueue` to execute the closure on. `.main` by default.
    ///   - closure: The closure to be executed periodically as data is sent to the server.
    ///
    /// - Returns:   The instance.
    @preconcurrency
    @discardableResult
    public func uploadProgress(queue: DispatchQueue = .main, closure: @escaping ProgressHandler) -> Self {
        mutableState.uploadProgressHandler = (handler: closure, queue: queue)

        return self
    }

    // MARK: Redirects

    /// Sets the redirect handler for the instance which will be used if a redirect response is encountered.
    ///
    /// - Note: Attempting to set the redirect handler more than once is a logic error and will crash.
    ///
    /// - Parameter handler: The `RedirectHandler`.
    ///
    /// - Returns:           The instance.
    @preconcurrency
    @discardableResult
    public func redirect(using handler: any RedirectHandler) -> Self {
        mutableState.write { mutableState in
            precondition(mutableState.redirectHandler == nil, "Redirect handler has already been set.")
            mutableState.redirectHandler = handler
        }

        return self
    }

    // MARK: Cached Responses

    /// Sets the cached response handler for the `Request` which will be used when attempting to cache a response.
    ///
    /// - Note: Attempting to set the cache handler more than once is a logic error and will crash.
    ///
    /// - Parameter handler: The `CachedResponseHandler`.
    ///
    /// - Returns:           The instance.
    @preconcurrency
    @discardableResult
    public func cacheResponse(using handler: any CachedResponseHandler) -> Self {
        mutableState.write { mutableState in
            precondition(mutableState.cachedResponseHandler == nil, "Cached response handler has already been set.")
            mutableState.cachedResponseHandler = handler
        }

        return self
    }

    // MARK: - Lifetime APIs

    /// Sets a handler to be called when the cURL description of the request is available.
    ///
    /// - Note: When waiting for a `Request`'s `URLRequest` to be created, only the last `handler` will be called.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which `handler` will be called.
    ///   - handler: Closure to be called when the cURL description is available.
    ///
    /// - Returns:           The instance.
    @preconcurrency
    @discardableResult
    public func cURLDescription(on queue: DispatchQueue, calling handler: @escaping @Sendable (String) -> Void) -> Self {
        mutableState.write { mutableState in
            if mutableState.requests.last != nil {
                queue.async { handler(self.cURLDescription()) }
            } else {
                mutableState.cURLHandler = (queue, handler)
            }
        }

        return self
    }

    /// Sets a handler to be called when the cURL description of the request is available.
    ///
    /// - Note: When waiting for a `Request`'s `URLRequest` to be created, only the last `handler` will be called.
    ///
    /// - Parameter handler: Closure to be called when the cURL description is available. Called on the instance's
    ///                      `underlyingQueue` by default.
    ///
    /// - Returns:           The instance.
    @preconcurrency
    @discardableResult
    public func cURLDescription(calling handler: @escaping @Sendable (String) -> Void) -> Self {
        cURLDescription(on: underlyingQueue, calling: handler)

        return self
    }

    /// Sets a closure to called whenever Alamofire creates a `URLRequest` for this instance.
    ///
    /// - Note: This closure will be called multiple times if the instance adapts incoming `URLRequest`s or is retried.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which `handler` will be called. `.main` by default.
    ///   - handler: Closure to be called when a `URLRequest` is available.
    ///
    /// - Returns:   The instance.
    @preconcurrency
    @discardableResult
    public func onURLRequestCreation(on queue: DispatchQueue = .main, perform handler: @escaping @Sendable (URLRequest) -> Void) -> Self {
        mutableState.write { state in
            if let request = state.requests.last {
                queue.async { handler(request) }
            }

            state.urlRequestHandler = (queue, handler)
        }

        return self
    }

    /// Sets a closure to be called whenever the instance creates a `URLSessionTask`.
    ///
    /// - Note: This API should only be used to provide `URLSessionTask`s to existing API, like `NSFileProvider`. It
    ///         **SHOULD NOT** be used to interact with tasks directly, as that may be break Alamofire features.
    ///         Additionally, this closure may be called multiple times if the instance is retried.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which `handler` will be called. `.main` by default.
    ///   - handler: Closure to be called when the `URLSessionTask` is available.
    ///
    /// - Returns:   The instance.
    @preconcurrency
    @discardableResult
    public func onURLSessionTaskCreation(on queue: DispatchQueue = .main, perform handler: @escaping @Sendable (URLSessionTask) -> Void) -> Self {
        mutableState.write { state in
            if let task = state.tasks.last {
                queue.async { handler(task) }
            }

            state.urlSessionTaskHandler = (queue, handler)
        }

        return self
    }

    // MARK: Cleanup

    /// Adds a `finishHandler` closure to be called when the request completes.
    /// 添加请求完成时要执行的处理器
    ///
    /// - Parameter closure: Closure to be called when the request finishes.    请求完成时要执行的闭包
    func onFinish(perform finishHandler: @escaping () -> Void) {
        /// 如果请求已完成，直接执行处理器
        guard !isFinished else { finishHandler(); return }

        /// 否则添加到完成处理器列表
        mutableState.write { state in
            state.finishHandlers.append(finishHandler)
        }
    }

    /// Final cleanup step executed when the instance finishes response serialization.
    /// 请求完成时的最终清理步骤
    func cleanup() {
        /// 执行所有完成处理器
        let handlers = mutableState.finishHandlers
        handlers.forEach { $0() }
        
        /// 清空处理器列表
        mutableState.write { state in
            state.finishHandlers.removeAll()
        }

        /// 通知代理进行清理appendResponseSerializer
        delegate?.cleanup(after: self)
    }
}

extension Request {
    /// Type indicating how a `DataRequest` or `DataStreamRequest` should proceed after receiving an `HTTPURLResponse`.
    /// 定义不同的响应处理策略
    /// 决定如何处理接收到的 HTTPURLResponse
    public enum ResponseDisposition: Sendable {
        /// Allow the request to continue normally.
        /// 允许请求继续正常处理
        case allow
        /// Cancel the request, similar to calling `cancel()`.
        /// 取消请求，类似于调用 cancel（）
        case cancel

        /// 转换为 URLSession.ResponseDisposition 的响应处理策略
        var sessionDisposition: URLSession.ResponseDisposition {
            switch self {
            case .allow: .allow
            case .cancel: .cancel
            }
        }
    }
}

// MARK: - Protocol Conformances

/// 实现 Equatable 协议，比较两个请求是否相等
extension Request: Equatable {
    public static func ==(lhs: Request, rhs: Request) -> Bool {
        /// 通过 唯一标识符比较
        lhs.id == rhs.id
    }
}

/// 实现 Hashable 协议，支持作为字典键或集合元素
extension Request: Hashable {
    public func hash(into hasher: inout Hasher) {
        /// 使用 唯一标识符作为哈希值
        hasher.combine(id)
    }
}

/// 实现 CustomStringConvertible 协议，提供可读性描述
extension Request: CustomStringConvertible {
    /// A textual representation of this instance, including the `HTTPMethod` and `URL` if the `URLRequest` has been
    /// created, as well as the response status code, if a response has been received.
    /// 提供 包含 HTTP 方法、URL 和 响应状态码的文本描述
    public var description: String {
        guard let request = performedRequests.last ?? lastRequest,
              let url = request.url,
              let method = request.httpMethod else { return "No request created yet." }

        let requestDescription = "\(method) \(url.absoluteString)"

        return response.map { "\(requestDescription) (\($0.statusCode))" } ?? requestDescription
    }
}

extension Request {
    /// cURL representation of the instance.
    ///
    /// - Returns: The cURL equivalent of the instance.
    /// /// 生成当前请求的 cURL 命令表示形式
    /// 主要用于调试目的，可以直接在终端中执行生成的命令
    public func cURLDescription() -> String {
        // 确保请求包含必要的基本信息
        guard
            let request = lastRequest,
            let url = request.url,
            let host = url.host,
            let method = request.httpMethod else { return "$ curl command could not be created" }

        // 构建 cURL 命令的各个组件
        var components = ["$ curl -v"]

        // 添加 HTTP 方法
        components.append("-X \(method)")

        // 处理认证信息
        if let credentialStorage = delegate?.sessionConfiguration.urlCredentialStorage {
            let protectionSpace = URLProtectionSpace(host: host,
                                                     port: url.port ?? 0,
                                                     protocol: url.scheme,
                                                     realm: host,
                                                     authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

            // 添加存储的认证信息
            if let credentials = credentialStorage.credentials(for: protectionSpace)?.values {
                for credential in credentials {
                    guard let user = credential.user, let password = credential.password else { continue }
                    components.append("-u \(user):\(password)")
                }
            } else {
                // 添加请求级别的认证信息
                if let credential, let user = credential.user, let password = credential.password {
                    components.append("-u \(user):\(password)")
                }
            }
        }

        // 处理 Cookie
        if let configuration = delegate?.sessionConfiguration, configuration.httpShouldSetCookies {
            if
                let cookieStorage = configuration.httpCookieStorage,
                let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty {
                let allCookies = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: ";")

                components.append("-b \"\(allCookies)\"")
            }
        }

        // 处理请求头
        var headers = HTTPHeaders()

        // 添加会话配置中的头部
        if let sessionHeaders = delegate?.sessionConfiguration.headers {
            for header in sessionHeaders where header.name != "Cookie" {
                headers[header.name] = header.value
            }
        }

        // 添加请求特定的头部
        for header in request.headers where header.name != "Cookie" {
            headers[header.name] = header.value
        }

        for header in headers {
            let escapedValue = header.value.replacingOccurrences(of: "\"", with: "\\\"")
            components.append("-H \"\(header.name): \(escapedValue)\"")
        }

        // 处理请求体
        if let httpBodyData = request.httpBody {
            let httpBody = String(decoding: httpBodyData, as: UTF8.self)
            var escapedBody = httpBody.replacingOccurrences(of: "\\\"", with: "\\\\\"")
            escapedBody = escapedBody.replacingOccurrences(of: "\"", with: "\\\"")

            components.append("-d \"\(escapedBody)\"")
        }

        // 添加 URL
        components.append("\"\(url.absoluteString)\"")

        // 将所有组件用换行和制表符连接，使输出更易读
        return components.joined(separator: " \\\n\t")
    }
}

/// Protocol abstraction for `Request`'s communication back to the `SessionDelegate`.
/// 该协议 定义了 Request 与 SessionDelegate 之间的通信接口
public protocol RequestDelegate: AnyObject, Sendable {
    /// `URLSessionConfiguration` used to create the underlying `URLSessionTask`s.
    /// 用于创建底层 URLSessionTask 的配置
    var sessionConfiguration: URLSessionConfiguration { get }

    /// Determines whether the `Request` should automatically call `resume()` when adding the first response handler.
    /// 决定是否在添加第一个响应处理器时自动调用 resume()
    var startImmediately: Bool { get }

    /// Notifies the delegate the `Request` has reached a point where it needs cleanup.
    /// 通知代理请求需要清理
    ///
    /// - Parameter request: The `Request` to cleanup after.    需要清理的请求
    func cleanup(after request: Request)

    /// Asynchronously ask the delegate whether a `Request` will be retried.
    /// 异步询问代理是否需要重试请求
    ///
    /// - Parameters:
    ///   - request:    `Request` which failed.     失败的请求
    ///   - error:      `Error` which produced the failure.
    ///   - completion: Closure taking the `RetryResult` for evaluation.
    func retryResult(for request: Request, dueTo error: AFError, completion: @escaping @Sendable (RetryResult) -> Void)

    /// Asynchronously retry the `Request`.
    ///
    /// - Parameters:
    ///   - request:   `Request` which will be retried.
    ///   - timeDelay: `TimeInterval` after which the retry will be triggered.      重试延迟时间
    func retryRequest(_ request: Request, withDelay timeDelay: TimeInterval?)
}
