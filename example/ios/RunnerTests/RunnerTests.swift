import Flutter
import UIKit
import XCTest

@testable import voice_command

class RunnerTests: XCTestCase {

  func testIsListeningReturnsFalseInitially() {
    let plugin = VoiceCommandPlugin()
    let call = FlutterMethodCall(methodName: "isListening", arguments: nil)
    let expectResult = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! Bool, false)
      expectResult.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testStopListeningWhenNotListeningSucceeds() {
    let plugin = VoiceCommandPlugin()
    let call = FlutterMethodCall(methodName: "stopListening", arguments: nil)
    let expectResult = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertNil(result)
      expectResult.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testPauseWhenNotListeningSucceeds() {
    let plugin = VoiceCommandPlugin()
    let call = FlutterMethodCall(methodName: "pauseListening", arguments: nil)
    let expectResult = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertNil(result)
      expectResult.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
