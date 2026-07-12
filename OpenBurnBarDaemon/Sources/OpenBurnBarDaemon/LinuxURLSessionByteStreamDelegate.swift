import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

#if os(Linux)
// All mutable state (continuations, buffered result, termination handler) is guarded
// by the NSLock below; the NSObject/URLSessionDataDelegate constraint rules out an
// actor. sendable-allowlist: nslock-protected-storage
final class LinuxURLSessionByteStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct ResponseHead {
        let statusCode: Int
        let contentType: String
    }

    private let lock = NSLock()
    private let defaultContentType: String
    private let inactivityTimeoutNanoseconds: UInt64
    private var responseContinuation: CheckedContinuation<ResponseHead, Error>?
    private var responseResult: Result<ResponseHead, Error>?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var terminationHandler: (() -> Void)?
    private var successStatusCode: Int?
    private var upstreamErrorStatusCode: Int?
    private var upstreamErrorData = Data()
    private var upstreamErrorHeaders: [String: String] = [:]
    private var finished = false
    private var inactivityGeneration: UInt64 = 0

    init(defaultContentType: String, inactivityTimeoutNanoseconds: UInt64) {
        self.defaultContentType = defaultContentType
        self.inactivityTimeoutNanoseconds = inactivityTimeoutNanoseconds
    }

    func makeStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            streamContinuation = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                let handler = self?.terminationHandler
                self?.lock.unlock()
                handler?()
            }
        }
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        terminationHandler = handler
        lock.unlock()
    }

    func awaitHTTPResponse() async throws -> ResponseHead {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let responseResult {
                lock.unlock()
                continuation.resume(with: responseResult)
            } else {
                responseContinuation = continuation
                lock.unlock()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completeResponse(.failure(BurnBarProviderExecutorError.invalidResponse))
            completionHandler(.cancel)
            return
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? defaultContentType
        if (200..<300).contains(httpResponse.statusCode) {
            lock.lock()
            successStatusCode = httpResponse.statusCode
            lock.unlock()
            armInactivityTimeout()
            completeResponse(.success(ResponseHead(statusCode: httpResponse.statusCode, contentType: contentType)))
        } else {
            lock.lock()
            upstreamErrorStatusCode = httpResponse.statusCode
            upstreamErrorHeaders = BurnBarProxyStreaming.normalizedHeaders(from: httpResponse)
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isSuccess = successStatusCode != nil
        let continuation = streamContinuation
        if !isSuccess, upstreamErrorData.count < 64 * 1024 {
            upstreamErrorData.append(data.prefix(max(0, 64 * 1024 - upstreamErrorData.count)))
        }
        lock.unlock()

        if isSuccess, !data.isEmpty {
            armInactivityTimeout()
            continuation?.yield(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        inactivityGeneration &+= 1
        let continuation = streamContinuation
        let upstreamStatus = upstreamErrorStatusCode
        let upstreamBody = String(data: upstreamErrorData, encoding: .utf8) ?? ""
        let upstreamHeaders = upstreamErrorHeaders
        let sawSuccess = successStatusCode != nil
        lock.unlock()

        defer { session.finishTasksAndInvalidate() }

        if let error {
            completeResponse(.failure(error))
            continuation?.finish(throwing: error)
            return
        }

        if let upstreamStatus {
            let upstreamError = BurnBarProviderExecutorError.upstreamErrorWithHeaders(
                upstreamStatus,
                upstreamBody,
                upstreamHeaders
            )
            completeResponse(.failure(upstreamError))
            continuation?.finish(throwing: upstreamError)
            return
        }

        if sawSuccess {
            continuation?.finish()
        } else {
            let invalid = BurnBarProviderExecutorError.invalidResponse
            completeResponse(.failure(invalid))
            continuation?.finish(throwing: invalid)
        }
    }

    private func completeResponse(_ result: Result<ResponseHead, Error>) {
        lock.lock()
        if responseResult == nil {
            responseResult = result
            let continuation = responseContinuation
            responseContinuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        } else {
            lock.unlock()
        }
    }

    private func armInactivityTimeout() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        inactivityGeneration &+= 1
        let generation = inactivityGeneration
        let timeout = inactivityTimeoutNanoseconds
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            self?.timeoutIfCurrent(generation)
        }
    }

    private func timeoutIfCurrent(_ generation: UInt64) {
        lock.lock()
        guard !finished, inactivityGeneration == generation else {
            lock.unlock()
            return
        }
        finished = true
        inactivityGeneration &+= 1
        let continuation = streamContinuation
        lock.unlock()

        let error = URLError(.timedOut)
        completeResponse(.failure(error))
        continuation?.finish(throwing: error)
    }
}
#endif
