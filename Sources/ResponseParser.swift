// ResponseParser.swift
//
// The MIT License (MIT)
//
// Copyright (c) 2015 Zewo
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CHTTPParser

typealias ResponseContext = UnsafeMutablePointer<ResponseParserContext>

struct ResponseParserContext {
    var statusCode: Int = 0
    var reasonPhrase: String = ""
    var version: Version = Version(major: 0, minor: 0)
    var headers: Headers = [:]
    var cookieHeaders: Set<String> = []
    var body: Data = []
    
    var buildingHeaderName = ""
    var buildingCookieValue = ""
    var currentHeaderName: CaseInsensitiveString = ""
    var completion: (Response) -> Void
    
    init(completion: @escaping (Response) -> Void) {
        self.completion = completion
    }
}

var responseSettings: http_parser_settings = {
    var settings = http_parser_settings()
    http_parser_settings_init(&settings)
    
    settings.on_status           = onResponseStatus
    settings.on_header_field     = onResponseHeaderField
    settings.on_header_value     = onResponseHeaderValue
    settings.on_headers_complete = onResponseHeadersComplete
    settings.on_body             = onResponseBody
    settings.on_message_complete = onResponseMessageComplete
    
    return settings
}()

public final class ResponseParser : S4.ResponseParser {
    let stream: Stream
    let context: ResponseContext
    var parser = http_parser()
    var responses: [Response] = []
    let bufferSize: Int
    
    convenience public init(stream: Stream) {
        self.init(stream: stream, bufferSize: 2048)
    }
    
    public init(stream: Stream, bufferSize: Int) {
        self.stream = stream
        self.bufferSize = bufferSize
        self.context = ResponseContext.allocate(capacity: 1)
        self.context.initialize(to: ResponseParserContext { response in
            self.responses.insert(response, at: 0)
        })
        
        resetParser()
    }
    
    deinit {
        context.deallocate(capacity: 1)
    }
    
    func resetParser() {
        http_parser_init(&parser, HTTP_RESPONSE)
        parser.data = UnsafeMutableRawPointer(context)
    }
    
    public func parse() throws -> Response {
        while true {
            if let response = responses.popLast() {
                return response
            }
            
            let data = try stream.receive(upTo: bufferSize)
            let pointer = UnsafeRawPointer(data.bytes).assumingMemoryBound(to: Int8.self)
            let bytesParsed = http_parser_execute(&parser, &responseSettings, pointer, data.count)
            
            guard bytesParsed == data.count else {
                defer { resetParser() }
                throw http_errno(parser.http_errno)
            }
        }
    }
}

func onResponseStatus(_ parser: Parser?, data: UnsafePointer<Int8>?, length: Int) -> Int32 {
    return parser!.pointee.data.assumingMemoryBound(to: ResponseParserContext.self).withPointee {
        let reasonPhrase = String(cString: data!, length: length)
        $0.reasonPhrase += reasonPhrase
        return 0
    }
}

func onResponseHeaderField(_ parser: Parser?, data: UnsafePointer<Int8>?, length: Int) -> Int32 {
    return parser!.pointee.data.assumingMemoryBound(to: ResponseParserContext.self).withPointee {
        let headerName = String(cString: data!, length: length)
        
        if $0.currentHeaderName != "" {
            $0.currentHeaderName = ""
        }
        
        if $0.buildingCookieValue != "" {
            $0.cookieHeaders.insert($0.buildingCookieValue)
            $0.buildingCookieValue = ""
        }
        
        $0.buildingHeaderName += headerName
        return 0
    }
}

func onResponseHeaderValue(_ parser: Parser?, data: UnsafePointer<Int8>?, length: Int) -> Int32 {
    return parser!.pointee.data.assumingMemoryBound(to: ResponseParserContext.self).withPointee {
        let headerValue = String(cString: data!, length: length)
        
        if $0.currentHeaderName == "" {
            $0.currentHeaderName = CaseInsensitiveString($0.buildingHeaderName)
            $0.buildingHeaderName = ""
            
            if let previousHeaderValue = $0.headers[$0.currentHeaderName] {
                $0.headers[$0.currentHeaderName] = previousHeaderValue + ", "
            }
        }
        
        if $0.currentHeaderName == "Set-Cookie" {
            $0.buildingCookieValue += headerValue
        } else {
            let previousHeaderValue = $0.headers[$0.currentHeaderName] ?? ""
            $0.headers[$0.currentHeaderName] = previousHeaderValue + headerValue
        }
        
        return 0
    }
}

func onResponseHeadersComplete(_ parser: Parser?) -> Int32 {
    return parser!.pointee.data.assumingMemoryBound(to: ResponseParserContext.self).withPointee {
        if $0.buildingCookieValue != "" {
            $0.cookieHeaders.insert($0.buildingCookieValue)
            $0.buildingCookieValue = ""
        }
        
        $0.buildingHeaderName = ""
        $0.currentHeaderName = ""
        $0.statusCode = Int(parser!.pointee.status_code)
        let major = Int(parser!.pointee.http_major)
        let minor = Int(parser!.pointee.http_minor)
        $0.version = Version(major: major, minor: minor)
        return 0
    }
}

func onResponseBody(_ parser: Parser?, data: UnsafePointer<Int8>?, length: Int) -> Int32 {
    return parser!.pointee.data.assumingMemoryBound(to: ResponseParserContext.self).withPointee {
        let pointer = UnsafeRawPointer(data!).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: pointer, count: length)
        $0.body += Data(Array(buffer))
        return 0
    }
}

func onResponseMessageComplete(_ parser: Parser?) -> Int32 {
    return parser!.pointee.data.assumingMemoryBound(to: ResponseParserContext.self).withPointee {
        let response = Response(
            version: $0.version,
            status: Status(statusCode: $0.statusCode, reasonPhrase: $0.reasonPhrase),
            headers: $0.headers,
            cookieHeaders: $0.cookieHeaders,
            body: .buffer($0.body)
        )
        
        $0.completion(response)
        $0.statusCode = 0
        $0.reasonPhrase = ""
        $0.version = Version(major: 0, minor: 0)
        $0.headers = [:]
        $0.cookieHeaders = []
        $0.body = []
        return 0
    }
}
