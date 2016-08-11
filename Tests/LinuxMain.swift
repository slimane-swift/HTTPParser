import XCTest

@testable import HTTPParserTests

XCTMain([
    testCase(RequestParserTests.allTests),
    testCase(ResponseParserTests.allTests),
])