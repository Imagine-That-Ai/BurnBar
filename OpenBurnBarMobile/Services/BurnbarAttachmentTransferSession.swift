import Foundation

/// Background URLSession for chunked burnbar attachment PUTs.
/// Force-quit from the app switcher cancels all background transfers.
final class BurnbarAttachmentTransferSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let identifier = "com.openburnbar.burnbar-attachments"

    private(set) var resumeDataByPart: [String: Data] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func uploadFile(fileURL: URL, signedURL: URL, partKey: String) -> URLSessionUploadTask {
        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
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
        completionHandler()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let resume = (error as? URLError)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
              let key = task.taskDescription else { return }
        storeResumeData(resume, partKey: key)
    }
}
