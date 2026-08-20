import Foundation

/// Background URLSession for chunked burnbar attachment PUTs.
/// Force-quit from the app switcher cancels all background transfers.
final class BurnbarAttachmentTransferSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let identifier = "com.openburnbar.burnbar-attachments"

    private(set) var resumeDataByPart: [String: Data] = [:]
    private var session: URLSession!
    private var backgroundCompletion: (() -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    static func signedPutRequest(fileURL: URL, signedURL: URL) -> URLRequest {
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let length = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "x-goog-if-generation-match")
        return request
    }

    func uploadFile(fileURL: URL, signedURL: URL, partKey: String) -> URLSessionUploadTask {
        let request = Self.signedPutRequest(fileURL: fileURL, signedURL: signedURL)
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = partKey
        task.resume()
        return task
    }

    func storeResumeData(_ data: Data, partKey: String) {
        resumeDataByPart[partKey] = data
    }

    func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else {
            completionHandler()
            return
        }
        backgroundCompletion = completionHandler
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletion
        backgroundCompletion = nil
        handler?()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionUploadTaskResumeData] as? Data
            ?? nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        guard let resume, let key = task.taskDescription else { return }
        storeResumeData(resume, partKey: key)
    }
}
