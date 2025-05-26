//
//  DataRequest.swift
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

/// `Request` subclass which handles in-memory `Data` download using `URLSessionDataTask`.
/// - 管理请求数据的接收和存储
/// - 处理响应回调
/// - 支持数据序列化
public class DataRequest: Request, @unchecked Sendable {
    /// `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    public let convertible: any URLRequestConvertible
    /// `Data` read from the server so far.
    /// 存储服务器返回的数据
    /// 通过线程安全的方式访问存储的数据
    public var data: Data? { dataMutableState.data }

    private struct DataMutableState {
        var data: Data?
        /// HTTP 响应处理器，处理服务器返回的响应
        var httpResponseHandler: (queue: DispatchQueue,
                                  handler: @Sendable (_ response: HTTPURLResponse,
                                                      _ completionHandler: @escaping @Sendable (ResponseDisposition) -> Void) -> Void)?
    }

    private let dataMutableState = Protected(DataMutableState())

    /// Creates a `DataRequest` using the provided parameters.
    ///
    /// - Parameters:
    ///   - id:                 `UUID` used for the `Hashable` and `Equatable` implementations. `UUID()` by default.
    ///   请求的唯一标识符
    ///   - convertible:        `URLRequestConvertible` value used to create `URLRequest`s for this instance.
    ///   用于创建 URLRequest 的对象
    ///   - underlyingQueue:    `DispatchQueue` on which all internal `Request` work is performed.
    ///   内部操作执行的队列
    ///   - serializationQueue: `DispatchQueue` on which all serialization work is performed. By default targets
    ///                         `underlyingQueue`, but can be passed another queue from a `Session`.
    ///                         序列化操作执行的队列
    ///   - eventMonitor:       `EventMonitor` called for event callbacks from internal `Request` actions.
    ///   事件监控器
    ///   - interceptor:        `RequestInterceptor` used throughout the request lifecycle.
    ///   请求拦截器
    ///   - delegate:           `RequestDelegate` that provides an interface to actions not performed by the `Request`.
    ///   请求委托对象
    init(id: UUID = UUID(),
         convertible: any URLRequestConvertible,
         underlyingQueue: DispatchQueue,
         serializationQueue: DispatchQueue,
         eventMonitor: (any EventMonitor)?,
         interceptor: (any RequestInterceptor)?,
         delegate: any RequestDelegate) {
        self.convertible = convertible

        super.init(id: id,
                   underlyingQueue: underlyingQueue,
                   serializationQueue: serializationQueue,
                   eventMonitor: eventMonitor,
                   interceptor: interceptor,
                   delegate: delegate)
    }

    /// 重置请求状态，清除已接收的数据
    override func reset() {
        super.reset()

        dataMutableState.write { mutableState in
            mutableState.data = nil
        }
    }

    /// Called when `Data` is received by this instance.
    /// 处理接收到的数据
    ///
    /// - Note: Also calls `updateDownloadProgress`.
    /// 同时会更新下载进度
    ///
    /// - Parameter data: The `Data` received.
    func didReceive(data: Data) {
        dataMutableState.write { mutableState in
            if mutableState.data == nil {
                /// 如果是第一次接受数据，直接保存
                mutableState.data = data
            } else {
                /// 否则追加到现有数据后面
                mutableState.data?.append(data)
            }
        }

        /// 更新下载进度
        updateDownloadProgress()
    }

    /// 处理收到 HTTP 响应的回调
    /// - Parameters:
    ///   - response: 服务器返回的 HTTP 响应
    ///   - completionHandler: 完成处理器，用于控制如何处理响应
    
    func didReceiveResponse(_ response: HTTPURLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        dataMutableState.read { dataMutableState in
            /// 如果没有响应处理器，默认允许继续
            guard let httpResponseHandler = dataMutableState.httpResponseHandler else {
                underlyingQueue.async { completionHandler(.allow) }
                return
            }

            /// 在指队列上异步执行响应处理
            httpResponseHandler.queue.async {
                httpResponseHandler.handler(response) { disposition in
                    /// 如果处理结果是取消，更新请求状态
                    if disposition == .cancel {
                        self.mutableState.write { mutableState in
                            mutableState.state = .cancelled
                            mutableState.error = mutableState.error ?? AFError.explicitlyCancelled
                        }
                    }

                    /// 在底层队列上执行完成处理
                    self.underlyingQueue.async {
                        completionHandler(disposition.sessionDisposition)
                    }
                }
            }
        }
    }

    
    /// 创建用于执行请求的 URLSessionTask。
    /// - Parameters:
    ///   - request: 要执行的请求
    ///   - session: 用于创建任务的会话
    /// - Returns: 创建的数据任务
    override func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let copiedRequest = request
        return session.dataTask(with: copiedRequest)
    }

    /// Called to update the `downloadProgress` of the instance.
    /// 更新下载进度
    /// 根据已接收的数据大小和预期的总大小计算进度
    func updateDownloadProgress() {
        let totalBytesReceived = Int64(data?.count ?? 0)
        let totalBytesExpected = task?.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown

        downloadProgress.totalUnitCount = totalBytesExpected
        downloadProgress.completedUnitCount = totalBytesReceived

        /// 在指定队列上异步执行进度回调
        downloadProgressHandler?.queue.async { self.downloadProgressHandler?.handler(self.downloadProgress) }
    }

    /// Validates the request, using the specified closure.
    ///
    /// - Note: If validation fails, subsequent calls to response handlers will have an associated error.
    ///
    /// - Parameter validation: `Validation` closure used to validate the response.     验证闭包，用于验证响应是否有效
    ///
    /// - Returns:              The instance.
    @preconcurrency
    @discardableResult
    public func validate(_ validation: @escaping Validation) -> Self {
        let validator: @Sendable () -> Void = { [unowned self] in
            /// 只有在没有错误且存在响应时才进行验证
            guard error == nil, let response else { return }

            /// 执行验证
            let result = validation(request, response, data)

            /// 如果验证失败，设置错误
            if case let .failure(error) = result { self.error = error.asAFError(or: .responseValidationFailed(reason: .customValidationFailed(error: error))) }

            /// 通知事件监听器验证结果
            eventMonitor?.request(self,
                                  didValidateRequest: request,
                                  response: response,
                                  data: data,
                                  withResult: result)
        }

        /// 添加验证器到验证队列
        validators.write { $0.append(validator) }

        return self
    }

    /// 设置 HTTP 响应处理器
    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse` and providing a completion
    /// handler to return a `ResponseDisposition` value.
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.       处理器执行的队列，默认主队列
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`. The `completionHandler` provided
    ///              MUST be called, otherwise the request will never complete.     收到 HTTP 响应时的处理闭包，必须调用提供的 handler
    ///
    /// - Returns:   The instance.
    @_disfavoredOverload
    @preconcurrency
    @discardableResult
    public func onHTTPResponse(
        on queue: DispatchQueue = .main,
        perform handler: @escaping @Sendable (_ response: HTTPURLResponse,
                                              _ completionHandler: @escaping @Sendable (ResponseDisposition) -> Void) -> Void
    ) -> Self {
        dataMutableState.write { mutableState in
            mutableState.httpResponseHandler = (queue, handler)
        }

        return self
    }

    /// Sets a closure called whenever the `DataRequest` produces an `HTTPURLResponse`.
    /// 简化版的 HTTP 响应处理器设置
    ///
    /// - Parameters:
    ///   - queue:   `DispatchQueue` on which the closure will be called. `.main` by default.
    ///   - handler: Closure called when the instance produces an `HTTPURLResponse`.
    ///
    /// - Returns:   The instance.
    @preconcurrency
    @discardableResult
    public func onHTTPResponse(on queue: DispatchQueue = .main,
                               perform handler: @escaping @Sendable (HTTPURLResponse) -> Void) -> Self {
        onHTTPResponse(on: queue) { response, completionHandler in
            handler(response)
            /// 默认允许请求继续
            completionHandler(.allow)
        }

        return self
    }

    // MARK: Response Serialization
    /// 响应序列化

    /// Adds a handler to be called once the request has finished.
    /// 基础响应处理器
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. `.main` by default.     完成回调执行的队列
    ///   - completionHandler: The code to be executed once the request has finished.
    ///
    /// - Returns:             The request.
    @preconcurrency
    @discardableResult
    public func response(queue: DispatchQueue = .main, completionHandler: @escaping @Sendable (AFDataResponse<Data?>) -> Void) -> Self {
        appendResponseSerializer {
            // Start work that should be on the serialization queue.
            /// 创建结果对象
            let result = AFResult<Data?>(value: self.data, error: self.error)
            // End work that should be on the serialization queue.

            self.underlyingQueue.async {
                /// 构建响应对象
                let response = DataResponse(request: self.request,
                                            response: self.response,
                                            data: self.data,
                                            metrics: self.metrics,
                                            serializationDuration: 0,
                                            result: result)

                /// 通知事件监听器
                self.eventMonitor?.request(self, didParseResponse: response)

                /// 完成序列化并执行回调
                self.responseSerializerDidComplete { queue.async { completionHandler(response) } }
            }
        }

        return self
    }

    
    /// 通用响应序列化处理
    /// - Parameters:
    ///   - queue: 完成处理器调用的队列，默认主队列
    ///   - responseSerializer: 负责序列化请求、响应和数据的序列化器
    ///   - completionHandler: 请求完成时要执行的代码
    /// - Returns: 支持链式调用
    private func _response<Serializer: DataResponseSerializerProtocol>(queue: DispatchQueue = .main,
                                                                       responseSerializer: Serializer,
                                                                       completionHandler: @escaping @Sendable (AFDataResponse<Serializer.SerializedObject>) -> Void)
        -> Self {
        appendResponseSerializer {
            // Start work that should be on the serialization queue.
            /// 在序列化队列上执行的工作
            let start = ProcessInfo.processInfo.systemUptime
            let result: AFResult<Serializer.SerializedObject> = Result {
                try responseSerializer.serialize(request: self.request,
                                                 response: self.response,
                                                 data: self.data,
                                                 error: self.error)
            }.mapError { error in
                /// 将错误转换为 AFError
                error.asAFError(or: .responseSerializationFailed(reason: .customSerializationFailed(error: error)))
            }

            let end = ProcessInfo.processInfo.systemUptime
            // End work that should be on the serialization queue.

            /// 在底层队列上异步执行响应处理
            self.underlyingQueue.async {
                let response = DataResponse(request: self.request,
                                            response: self.response,
                                            data: self.data,
                                            metrics: self.metrics,
                                            serializationDuration: end - start,
                                            result: result)

                /// 通知事件监听器
                self.eventMonitor?.request(self, didParseResponse: response)

                /// 处理重试逻辑
                guard !self.isCancelled, let serializerError = result.failure, let delegate = self.delegate else {
                    /// 如果没有错误或已取消，直接完成
                    self.responseSerializerDidComplete { queue.async { completionHandler(response) } }
                    return
                }

                /// 询问代理是否需要重试
                delegate.retryResult(for: self, dueTo: serializerError) { retryResult in
                    var didComplete: (@Sendable () -> Void)?

                    defer {
                        if let didComplete {
                            self.responseSerializerDidComplete { queue.async { didComplete() } }
                        }
                    }

                    switch retryResult {
                    case .doNotRetry:
                        /// 不重试，直接返回响应
                        didComplete = { completionHandler(response) }

                    case let .doNotRetryWithError(retryError):
                        /// 使用新的错误创建响应
                        let result: AFResult<Serializer.SerializedObject> = .failure(retryError.asAFError(orFailWith: "Received retryError was not already AFError"))

                        let response = DataResponse(request: self.request,
                                                    response: self.response,
                                                    data: self.data,
                                                    metrics: self.metrics,
                                                    serializationDuration: end - start,
                                                    result: result)

                        didComplete = { completionHandler(response) }

                    case .retry, .retryWithDelay:
                        /// 进行重试
                        delegate.retryRequest(self, withDelay: retryResult.delay)
                    }
                }
            }
        }

        return self
    }

    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:              The queue on which the completion handler is dispatched. `.main` by default
    ///   - responseSerializer: The response serializer responsible for serializing the request, response, and data.
    ///   - completionHandler:  The code to be executed once the request has finished.
    ///
    /// - Returns:              The request.
    @preconcurrency
    @discardableResult
    public func response<Serializer: DataResponseSerializerProtocol>(queue: DispatchQueue = .main,
                                                                     responseSerializer: Serializer,
                                                                     completionHandler: @escaping @Sendable (AFDataResponse<Serializer.SerializedObject>) -> Void)
        -> Self {
        _response(queue: queue, responseSerializer: responseSerializer, completionHandler: completionHandler)
    }

    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:              The queue on which the completion handler is dispatched. `.main` by default
    ///   - responseSerializer: The response serializer responsible for serializing the request, response, and data.
    ///   - completionHandler:  The code to be executed once the request has finished.
    ///
    /// - Returns:              The request.
    @preconcurrency
    @discardableResult
    public func response<Serializer: ResponseSerializer>(queue: DispatchQueue = .main,
                                                         responseSerializer: Serializer,
                                                         completionHandler: @escaping @Sendable (AFDataResponse<Serializer.SerializedObject>) -> Void)
        -> Self {
        _response(queue: queue, responseSerializer: responseSerializer, completionHandler: completionHandler)
    }

    /// Adds a handler using a `DataResponseSerializer` to be called once the request has finished.
    /// 使用 DataResponseSerializer 将响应数据序列化为 Data 类型
    ///
    /// - Parameters:
    ///   - queue:               The queue on which the completion handler is called. `.main` by default.       完成回调执行的队列，默认主队列
    ///   - dataPreprocessor:    `DataPreprocessor` which processes the received `Data` before calling the
    ///                          `completionHandler`. `PassthroughPreprocessor()` by default.       数据预处理器，处理接收到的数据
    ///   - emptyResponseCodes:  HTTP status codes for which empty responses are always valid. `[204, 205]` by default.     允许空响应的 HTTP 状态码集合
    ///   - emptyRequestMethods: `HTTPMethod`s for which empty responses are always valid. `[.head]` by default.        允许空响应的 HTTP 请求方法集合
    ///   - completionHandler:   A closure to be executed once the request has finished.        请求完成时的回调闭包
    ///
    /// - Returns:               The request.
    @preconcurrency
    @discardableResult
    public func responseData(queue: DispatchQueue = .main,
                             dataPreprocessor: any DataPreprocessor = DataResponseSerializer.defaultDataPreprocessor,
                             emptyResponseCodes: Set<Int> = DataResponseSerializer.defaultEmptyResponseCodes,
                             emptyRequestMethods: Set<HTTPMethod> = DataResponseSerializer.defaultEmptyRequestMethods,
                             completionHandler: @escaping @Sendable (AFDataResponse<Data>) -> Void) -> Self {
        response(queue: queue,
                 responseSerializer: DataResponseSerializer(dataPreprocessor: dataPreprocessor,
                                                            emptyResponseCodes: emptyResponseCodes,
                                                            emptyRequestMethods: emptyRequestMethods),
                 completionHandler: completionHandler)
    }

    /// Adds a handler using a `StringResponseSerializer` to be called once the request has finished.
    /// 使用 StringResponseSerializer 将响应数据序列化为 String 类型
    ///
    /// - Parameters:
    ///   - queue:               The queue on which the completion handler is dispatched. `.main` by default.
    ///   - dataPreprocessor:    `DataPreprocessor` which processes the received `Data` before calling the
    ///                          `completionHandler`. `PassthroughPreprocessor()` by default.
    ///   - encoding:            The string encoding. Defaults to `nil`, in which case the encoding will be determined
    ///                          from the server response, falling back to the default HTTP character set, `ISO-8859-1`.
    ///                          字符串编码方式，默认从服务器响应推断
    ///   - emptyResponseCodes:  HTTP status codes for which empty responses are always valid. `[204, 205]` by default.
    ///   - emptyRequestMethods: `HTTPMethod`s for which empty responses are always valid. `[.head]` by default.
    ///   - completionHandler:   A closure to be executed once the request has finished.
    ///
    /// - Returns:               The request.
    @preconcurrency
    @discardableResult
    public func responseString(queue: DispatchQueue = .main,
                               dataPreprocessor: any DataPreprocessor = StringResponseSerializer.defaultDataPreprocessor,
                               encoding: String.Encoding? = nil,
                               emptyResponseCodes: Set<Int> = StringResponseSerializer.defaultEmptyResponseCodes,
                               emptyRequestMethods: Set<HTTPMethod> = StringResponseSerializer.defaultEmptyRequestMethods,
                               completionHandler: @escaping @Sendable (AFDataResponse<String>) -> Void) -> Self {
        response(queue: queue,
                 responseSerializer: StringResponseSerializer(dataPreprocessor: dataPreprocessor,
                                                              encoding: encoding,
                                                              emptyResponseCodes: emptyResponseCodes,
                                                              emptyRequestMethods: emptyRequestMethods),
                 completionHandler: completionHandler)
    }

    /// Adds a handler using a `JSONResponseSerializer` to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:               The queue on which the completion handler is dispatched. `.main` by default.
    ///   - dataPreprocessor:    `DataPreprocessor` which processes the received `Data` before calling the
    ///                          `completionHandler`. `PassthroughPreprocessor()` by default.
    ///   - emptyResponseCodes:  HTTP status codes for which empty responses are always valid. `[204, 205]` by default.
    ///   - emptyRequestMethods: `HTTPMethod`s for which empty responses are always valid. `[.head]` by default.
    ///   - options:             `JSONSerialization.ReadingOptions` used when parsing the response. `.allowFragments`
    ///                          by default.
    ///   - completionHandler:   A closure to be executed once the request has finished.
    ///
    /// - Returns:               The request.
    @available(*, deprecated, message: "responseJSON deprecated and will be removed in Alamofire 6. Use responseDecodable instead.")
    @preconcurrency
    @discardableResult
    public func responseJSON(queue: DispatchQueue = .main,
                             dataPreprocessor: any DataPreprocessor = JSONResponseSerializer.defaultDataPreprocessor,
                             emptyResponseCodes: Set<Int> = JSONResponseSerializer.defaultEmptyResponseCodes,
                             emptyRequestMethods: Set<HTTPMethod> = JSONResponseSerializer.defaultEmptyRequestMethods,
                             options: JSONSerialization.ReadingOptions = .allowFragments,
                             completionHandler: @escaping @Sendable (AFDataResponse<Any>) -> Void) -> Self {
        response(queue: queue,
                 responseSerializer: JSONResponseSerializer(dataPreprocessor: dataPreprocessor,
                                                            emptyResponseCodes: emptyResponseCodes,
                                                            emptyRequestMethods: emptyRequestMethods,
                                                            options: options),
                 completionHandler: completionHandler)
    }

    /// Adds a handler using a `DecodableResponseSerializer` to be called once the request has finished.
    /// 使用 DecodableResponseSerializer 将响应数据解码为指定的 Decodable 类型
    ///
    /// - Parameters:
    ///   - type:                `Decodable` type to decode from response data.     要解码的目标类型
    ///   - queue:               The queue on which the completion handler is dispatched. `.main` by default.
    ///   - dataPreprocessor:    `DataPreprocessor` which processes the received `Data` before calling the
    ///                          `completionHandler`. `PassthroughPreprocessor()` by default.
    ///   - decoder:             `DataDecoder` to use to decode the response. `JSONDecoder()` by default.       数据解码器，默认使用 JSONDecoder
    ///   - emptyResponseCodes:  HTTP status codes for which empty responses are always valid. `[204, 205]` by default.
    ///   - emptyRequestMethods: `HTTPMethod`s for which empty responses are always valid. `[.head]` by default.
    ///   - completionHandler:   A closure to be executed once the request has finished.
    ///
    /// - Returns:               The request.
    @preconcurrency
    @discardableResult
    public func responseDecodable<Value>(of type: Value.Type = Value.self,
                                         queue: DispatchQueue = .main,
                                         dataPreprocessor: any DataPreprocessor = DecodableResponseSerializer<Value>.defaultDataPreprocessor,
                                         decoder: any DataDecoder = JSONDecoder(),
                                         emptyResponseCodes: Set<Int> = DecodableResponseSerializer<Value>.defaultEmptyResponseCodes,
                                         emptyRequestMethods: Set<HTTPMethod> = DecodableResponseSerializer<Value>.defaultEmptyRequestMethods,
                                         completionHandler: @escaping @Sendable (AFDataResponse<Value>) -> Void) -> Self where Value: Decodable, Value: Sendable {
        response(queue: queue,
                 responseSerializer: DecodableResponseSerializer(dataPreprocessor: dataPreprocessor,
                                                                 decoder: decoder,
                                                                 emptyResponseCodes: emptyResponseCodes,
                                                                 emptyRequestMethods: emptyRequestMethods),
                 completionHandler: completionHandler)
    }
}
