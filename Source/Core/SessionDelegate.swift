//
//  SessionDelegate.swift
//
//  Copyright (c) 2014-2018 Alamofire Software Foundation (http://alamofire.org/)
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

/// SessionDelegate 是 Alamofire 的核心类之一，实现了 URLSession 的各种代理方法，用于管理网络请求的生命周期。它充当了 URLSession 事件与Alamofire 请求对象之间的桥梁
/// 其中，重要的功能就是 将 URLSession 事件路由到对应的 Request 对象
/// 1、管理网络请求的生命周期
/// 2、处理身份验证挑战
/// 3、处理重定向
/// 4、管理上传/下载进度
/// 5、处理数据接收

/// Class which implements the various `URLSessionDelegate` methods to connect various Alamofire features.
open class SessionDelegate: NSObject, @unchecked Sendable {
    /// 用于处理文件操作，主要用于下载任务
    private let fileManager: FileManager

    /// 提供会话状态相关的信息和控制
    weak var stateProvider: (any SessionStateProvider)?
    /// 监控网络请求的各个阶段事件
    var eventMonitor: (any EventMonitor)?

    /// Creates an instance from the given `FileManager`.
    ///
    /// - Parameter fileManager: `FileManager` to use for underlying file management, such as moving downloaded files.
    ///                          `.default` by default.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Internal method to find and cast requests while maintaining some integrity checking.
    ///
    /// - Parameters:
    ///   - task: The `URLSessionTask` for which to find the associated `Request`.
    ///   - type: The `Request` subclass type to cast any `Request` associate with `task`.
    func request<R: Request>(for task: URLSessionTask, as type: R.Type) -> R? {
        guard let provider = stateProvider else {
            assertionFailure("StateProvider is nil for task \(task.taskIdentifier).")
            return nil
        }

        return provider.request(for: task) as? R
    }
}

/// Type which provides various `Session` state values.
/// 管理请求状态和任务的对应关系
protocol SessionStateProvider: AnyObject, Sendable {
    /// 服务器信任管理器，用于处理 SSL/TLS 验证
    var serverTrustManager: ServerTrustManager? { get }
    /// 重定向处理器，处理 HTTP 重定向
    var redirectHandler: (any RedirectHandler)? { get }
    /// 缓存响应处理器，管理响应缓存策略
    var cachedResponseHandler: (any CachedResponseHandler)? { get }

    /// 根据任务获取对应的请求对象
    func request(for task: URLSessionTask) -> Request?
    /// 通知收集到任务的性能指标
    func didGatherMetricsForTask(_ task: URLSessionTask)
    /// 通知任务完成
    func didCompleteTask(_ task: URLSessionTask, completion: @escaping () -> Void)
    /// 获取任务的认证凭证
    func credential(for task: URLSessionTask, in protectionSpace: URLProtectionSpace) -> URLCredential?
    /// 处理会话失效时的请求取消操作
    func cancelRequestsForSessionInvalidation(with error: (any Error)?)
}

// MARK: URLSessionDelegate
// 处理基本的会话事件
extension SessionDelegate: URLSessionDelegate {
    open func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        eventMonitor?.urlSession(session, didBecomeInvalidWithError: error)

        stateProvider?.cancelRequestsForSessionInvalidation(with: error)
    }
}

// MARK: URLSessionTaskDelegate
/// 处理任务级别的事件（完成、重定向、认证等）
extension SessionDelegate: URLSessionTaskDelegate {
    /// Result of a `URLAuthenticationChallenge` evaluation.
    typealias ChallengeEvaluation = (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?, error: AFError?)

    open func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didReceive challenge: URLAuthenticationChallenge,
                         completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        eventMonitor?.urlSession(session, task: task, didReceive: challenge)

        let evaluation: ChallengeEvaluation
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodNegotiate:
            evaluation = attemptCredentialAuthentication(for: challenge, belongingTo: task)
        #if canImport(Security)
        case NSURLAuthenticationMethodServerTrust:
            evaluation = attemptServerTrustAuthentication(with: challenge)
        case NSURLAuthenticationMethodClientCertificate:
            evaluation = attemptCredentialAuthentication(for: challenge, belongingTo: task)
        #endif
        default:
            evaluation = (.performDefaultHandling, nil, nil)
        }

        if let error = evaluation.error {
            stateProvider?.request(for: task)?.didFailTask(task, earlyWithError: error)
        }

        completionHandler(evaluation.disposition, evaluation.credential)
    }

    #if canImport(Security)
    /// Evaluates the server trust `URLAuthenticationChallenge` received.
    ///
    /// - Parameter challenge: The `URLAuthenticationChallenge`.
    ///
    /// - Returns:             The `ChallengeEvaluation`.
    func attemptServerTrustAuthentication(with challenge: URLAuthenticationChallenge) -> ChallengeEvaluation {
        let host = challenge.protectionSpace.host

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil, nil)
        }

        do {
            guard let evaluator = try stateProvider?.serverTrustManager?.serverTrustEvaluator(forHost: host) else {
                return (.performDefaultHandling, nil, nil)
            }

            try evaluator.evaluate(trust, forHost: host)

            return (.useCredential, URLCredential(trust: trust), nil)
        } catch {
            return (.cancelAuthenticationChallenge, nil, error.asAFError(or: .serverTrustEvaluationFailed(reason: .customEvaluationFailed(error: error))))
        }
    }
    #endif

    /// Evaluates the credential-based authentication `URLAuthenticationChallenge` received for `task`.
    ///
    /// - Parameters:
    ///   - challenge: The `URLAuthenticationChallenge`.
    ///   - task:      The `URLSessionTask` which received the challenge.
    ///
    /// - Returns:     The `ChallengeEvaluation`.
    func attemptCredentialAuthentication(for challenge: URLAuthenticationChallenge,
                                         belongingTo task: URLSessionTask) -> ChallengeEvaluation {
        guard challenge.previousFailureCount == 0 else {
            return (.rejectProtectionSpace, nil, nil)
        }

        guard let credential = stateProvider?.credential(for: task, in: challenge.protectionSpace) else {
            return (.performDefaultHandling, nil, nil)
        }

        return (.useCredential, credential, nil)
    }

    open func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didSendBodyData bytesSent: Int64,
                         totalBytesSent: Int64,
                         totalBytesExpectedToSend: Int64) {
        eventMonitor?.urlSession(session,
                                 task: task,
                                 didSendBodyData: bytesSent,
                                 totalBytesSent: totalBytesSent,
                                 totalBytesExpectedToSend: totalBytesExpectedToSend)

        stateProvider?.request(for: task)?.updateUploadProgress(totalBytesSent: totalBytesSent,
                                                                totalBytesExpectedToSend: totalBytesExpectedToSend)
    }

    open func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        eventMonitor?.urlSession(session, taskNeedsNewBodyStream: task)

        guard let request = request(for: task, as: UploadRequest.self) else {
            assertionFailure("needNewBodyStream did not find UploadRequest.")
            completionHandler(nil)
            return
        }

        completionHandler(request.inputStream())
    }

    open func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest,
                         completionHandler: @escaping (URLRequest?) -> Void) {
        eventMonitor?.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request)

        if let redirectHandler = stateProvider?.request(for: task)?.redirectHandler ?? stateProvider?.redirectHandler {
            redirectHandler.task(task, willBeRedirectedTo: request, for: response, completion: completionHandler)
        } else {
            completionHandler(request)
        }
    }

    open func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        eventMonitor?.urlSession(session, task: task, didFinishCollecting: metrics)

        stateProvider?.request(for: task)?.didGatherMetrics(metrics)

        stateProvider?.didGatherMetricsForTask(task)
    }

    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
//        NSLog("URLSession: \(session), task: \(task), didCompleteWithError: \(error)")
        eventMonitor?.urlSession(session, task: task, didCompleteWithError: error)

        let request = stateProvider?.request(for: task)

        stateProvider?.didCompleteTask(task) {
            request?.didCompleteTask(task, with: error.map { $0.asAFError(or: .sessionTaskFailed(error: $0)) })
        }
    }

    @available(macOS 10.13, iOS 11.0, tvOS 11.0, watchOS 4.0, *)
    open func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        eventMonitor?.urlSession(session, taskIsWaitingForConnectivity: task)
    }
}

// MARK: URLSessionDataDelegate

extension SessionDelegate: URLSessionDataDelegate {
    open func urlSession(_ session: URLSession,
                         dataTask: URLSessionDataTask,
                         didReceive response: URLResponse,
                         completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        eventMonitor?.urlSession(session, dataTask: dataTask, didReceive: response)

        guard let response = response as? HTTPURLResponse else { completionHandler(.allow); return }

        if let request = request(for: dataTask, as: DataRequest.self) {
            request.didReceiveResponse(response, completionHandler: completionHandler)
        } else if let request = request(for: dataTask, as: DataStreamRequest.self) {
            request.didReceiveResponse(response, completionHandler: completionHandler)
        } else {
            assertionFailure("dataTask did not find DataRequest or DataStreamRequest in didReceive response")
            completionHandler(.allow)
            return
        }
    }

    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        eventMonitor?.urlSession(session, dataTask: dataTask, didReceive: data)

        if let request = request(for: dataTask, as: DataRequest.self) {
            request.didReceive(data: data)
        } else if let request = request(for: dataTask, as: DataStreamRequest.self) {
            request.didReceive(data: data)
        } else {
            assertionFailure("dataTask did not find DataRequest or DataStreamRequest in didReceive data")
            return
        }
    }

    open func urlSession(_ session: URLSession,
                         dataTask: URLSessionDataTask,
                         willCacheResponse proposedResponse: CachedURLResponse,
                         completionHandler: @escaping (CachedURLResponse?) -> Void) {
        eventMonitor?.urlSession(session, dataTask: dataTask, willCacheResponse: proposedResponse)

        if let handler = stateProvider?.request(for: dataTask)?.cachedResponseHandler ?? stateProvider?.cachedResponseHandler {
            handler.dataTask(dataTask, willCacheResponse: proposedResponse, completion: completionHandler)
        } else {
            completionHandler(proposedResponse)
        }
    }
}

// MARK: URLSessionWebSocketDelegate

#if canImport(Darwin) && !canImport(FoundationNetworking)

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension SessionDelegate: URLSessionWebSocketDelegate {
    open func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // TODO: Add event monitor method.
//        NSLog("URLSession: \(session), webSocketTask: \(webSocketTask), didOpenWithProtocol: \(`protocol` ?? "None")")
        guard let request = request(for: webSocketTask, as: WebSocketRequest.self) else {
            return
        }

        request.didConnect(protocol: `protocol`)
    }

    open func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // TODO: Add event monitor method.
//        NSLog("URLSession: \(session), webSocketTask: \(webSocketTask), didCloseWithCode: \(closeCode.rawValue), reason: \(reason ?? Data())")
        guard let request = request(for: webSocketTask, as: WebSocketRequest.self) else {
            return
        }

        // On 2021 OSes and above, empty reason is returned as empty Data rather than nil, so make it nil always.
        let reason = (reason?.isEmpty == true) ? nil : reason
        request.didDisconnect(closeCode: closeCode, reason: reason)
    }
}

#endif

// MARK: URLSessionDownloadDelegate

extension SessionDelegate: URLSessionDownloadDelegate {
    open func urlSession(_ session: URLSession,
                         downloadTask: URLSessionDownloadTask,
                         didResumeAtOffset fileOffset: Int64,
                         expectedTotalBytes: Int64) {
        eventMonitor?.urlSession(session,
                                 downloadTask: downloadTask,
                                 didResumeAtOffset: fileOffset,
                                 expectedTotalBytes: expectedTotalBytes)
        guard let downloadRequest = request(for: downloadTask, as: DownloadRequest.self) else {
            assertionFailure("downloadTask did not find DownloadRequest.")
            return
        }

        downloadRequest.updateDownloadProgress(bytesWritten: fileOffset,
                                               totalBytesExpectedToWrite: expectedTotalBytes)
    }

    open func urlSession(_ session: URLSession,
                         downloadTask: URLSessionDownloadTask,
                         didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
        eventMonitor?.urlSession(session,
                                 downloadTask: downloadTask,
                                 didWriteData: bytesWritten,
                                 totalBytesWritten: totalBytesWritten,
                                 totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        guard let downloadRequest = request(for: downloadTask, as: DownloadRequest.self) else {
            assertionFailure("downloadTask did not find DownloadRequest.")
            return
        }

        downloadRequest.updateDownloadProgress(bytesWritten: bytesWritten,
                                               totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    open func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        eventMonitor?.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)

        guard let request = request(for: downloadTask, as: DownloadRequest.self) else {
            assertionFailure("downloadTask did not find DownloadRequest.")
            return
        }

        let (destination, options): (URL, DownloadRequest.Options)
        if let response = request.response {
            (destination, options) = request.destination(location, response)
        } else {
            // If there's no response this is likely a local file download, so generate the temporary URL directly.
            (destination, options) = (DownloadRequest.defaultDestinationURL(location), [])
        }

        eventMonitor?.request(request, didCreateDestinationURL: destination)

        do {
            if options.contains(.removePreviousFile), fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            if options.contains(.createIntermediateDirectories) {
                let directory = destination.deletingLastPathComponent()
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try fileManager.moveItem(at: location, to: destination)

            request.didFinishDownloading(using: downloadTask, with: .success(destination))
        } catch {
            request.didFinishDownloading(using: downloadTask, with: .failure(.downloadedFileMoveFailed(error: error,
                                                                                                       source: location,
                                                                                                       destination: destination)))
        }
    }
}
