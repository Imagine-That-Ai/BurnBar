import Foundation

enum CloudGatewayError: Error {
    case classified(CloudErrorClassification)
    var classification: CloudErrorClassification {
        switch self { case .classified(let c): return c }
    }
}
