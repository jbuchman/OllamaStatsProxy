import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

enum Dashboard {
    static func response() -> Response {
        resourceResponse(named: "dashboard.html") ?? Response(status: .notFound)
    }

    static func resourceResponse(named name: String) -> Response? {
        guard !name.contains("/"), !name.contains("\\"),
              let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Public"),
              let data = try? Data(contentsOf: url) else { return nil }
        var headers = HTTPFields()
        headers[.cacheControl] = "no-store"
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "html": headers[.contentType] = "text/html; charset=utf-8"
        case "css": headers[.contentType] = "text/css; charset=utf-8"
        case "js": headers[.contentType] = "text/javascript; charset=utf-8"
        default: headers[.contentType] = "application/octet-stream"
        }
        return Response(
            status: .ok, headers: headers,
            body: .init(byteBuffer: ByteBufferAllocator().buffer(bytes: data))
        )
    }
}
