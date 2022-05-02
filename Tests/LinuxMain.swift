import XCTest

import VarIntTests

var tests = [XCTestCaseEntry]()
tests += VarIntTests.allTests()
XCTMain(tests)
