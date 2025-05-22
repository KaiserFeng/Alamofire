//
//  MultipartUpload.swift
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

/// Internal type which encapsulates a `MultipartFormData` upload.
/// 大文件上传
final class MultipartUpload: @unchecked Sendable { // Must be @unchecked due to FileManager not being properly Sendable.
    private let _result = Protected<Result<UploadRequest.Uploadable, any Error>?>(nil)
    var result: Result<UploadRequest.Uploadable, any Error> {
        if let value = _result.read({ $0 }) {
            return value
        } else {
            let result = Result { try build() }
            _result.write(result)

            return result
        }
    }

    private let multipartFormData: Protected<MultipartFormData>

    let encodingMemoryThreshold: UInt64
    let request: any URLRequestConvertible
    let fileManager: FileManager

    init(encodingMemoryThreshold: UInt64,
         request: any URLRequestConvertible,
         multipartFormData: MultipartFormData) {
        self.encodingMemoryThreshold = encodingMemoryThreshold
        self.request = request
        fileManager = multipartFormData.fileManager
        self.multipartFormData = Protected(multipartFormData)
    }

    func build() throws -> UploadRequest.Uploadable {
        let uploadable: UploadRequest.Uploadable
        /// 策略模式：根据数据大小选择不同的上传策略
        if multipartFormData.contentLength < encodingMemoryThreshold {
            let data = try multipartFormData.read { try $0.encode() }

            /// 小文件策略：直接内存编码
            uploadable = .data(data)
        } else {
            let tempDirectoryURL = fileManager.temporaryDirectory
            let directoryURL = tempDirectoryURL.appendingPathComponent("org.alamofire.manager/multipart.form.data")
            let fileName = UUID().uuidString
            let fileURL = directoryURL.appendingPathComponent(fileName)

            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

            do {
                try multipartFormData.read { try $0.writeEncodedData(to: fileURL) }
            } catch {
                // Cleanup after attempted write if it fails.
                try? fileManager.removeItem(at: fileURL)
                throw error
            }

            /// 大文件策略：写入临时文件
            uploadable = .file(fileURL, shouldRemove: true)
        }

        return uploadable
    }
}

extension MultipartUpload: UploadConvertible {
    func asURLRequest() throws -> URLRequest {
        var urlRequest = try request.asURLRequest()

        multipartFormData.read { multipartFormData in
            urlRequest.headers.add(.contentType(multipartFormData.contentType))
        }

        return urlRequest
    }

    func createUploadable() throws -> UploadRequest.Uploadable {
        try result.get()
    }
}
