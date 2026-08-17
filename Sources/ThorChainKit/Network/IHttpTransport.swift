import Foundation

protocol IHttpTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: IHttpTransport, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: configuration, delegate: RedirectRejectingDelegate(), delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
