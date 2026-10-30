import Foundation
import XCTest
import TelegramApiObjC
@testable import TelegramApi

private func rendered(_ value: Any?) -> String {
    guard let value = value else { return "nil" }
    if case Optional<Any>.none = value as Any? { return "nil" }
    return loggerDescription(redact: false, of: value)
}

/// `Api.parseFunctionCall` (the in-process server's decoder) against every generated function
/// fixture: the decoded call names and describes the same arguments as the builder's description,
/// serializes back to the builder's bytes, and parses the fixture's result; and
/// `Api.serializeFunctionResult` writes that result back byte-identically.
final class FunctionCallTests: XCTestCase {
    func testEveryFunctionFixtureRoundTrips() {
        var count = 0
        for fixture in schemaFunctionFixtures {
            let (description, buffer, parse) = fixture.make()
            guard let call = Api.parseFunctionCall(buffer) else {
                XCTFail("\(fixture.name): not parsed")
                continue
            }
            XCTAssertEqual(call.name, description.name, fixture.name)
            XCTAssertEqual(call.serialized().makeData(), buffer.makeData(), fixture.name)
            let expected = description.parameters
            XCTAssertEqual(call.arguments.map(\.0), expected.map(\.0), fixture.name)
            for (argument, parameter) in zip(call.arguments, expected) {
                XCTAssertEqual(rendered(argument.1), rendered(parameter.1.value), "\(fixture.name).\(argument.0)")
            }

            let resultBytes = fixture.resultBytes()
            guard let result = parse(resultBytes) else {
                XCTFail("\(fixture.name): result not parsed")
                continue
            }
            XCTAssertNotNil(call.parseResult(resultBytes), fixture.name)
            XCTAssertEqual(Api.serializeFunctionResult(result)?.makeData(), resultBytes.makeData(), fixture.name)
            count += 1
        }
        XCTAssertGreaterThan(count, 1000)
    }

    func testTypedArgumentAccess() {
        let (_, buffer, _) = Api.functions.messages.sendMessage(flags: 0, peer: .inputPeerUser(Api.InputPeer.Cons_inputPeerUser(userId: 7, accessHash: 8)), replyTo: nil, message: "hi", randomId: 42, replyMarkup: nil, entities: nil, scheduleDate: nil, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil, richMessage: nil)
        let call = Api.parseFunctionCall(buffer)!
        XCTAssertEqual(call.name, "messages.sendMessage")
        XCTAssertEqual(call.argument("message"), "hi")
        XCTAssertEqual(call.argument("randomId"), Int64(42))
        let peer: Api.InputPeer? = call.argument("peer")
        if case let .inputPeerUser(data)? = peer {
            XCTAssertEqual(data.userId, 7)
        } else {
            XCTFail("peer not decoded: \(String(describing: peer))")
        }
        let missing: Api.InputReplyTo? = call.argument("replyTo")
        XCTAssertNil(missing)
        let entities: [Api.MessageEntity]? = call.elements("entities")
        XCTAssertNil(entities)
    }

    func testUnknownFunctionIdIsNotACall() {
        let buffer = Buffer()
        buffer.appendInt32(0x7fff_fff2)
        XCTAssertNil(Api.parseFunctionCall(buffer))
        XCTAssertNil(Api.parseFunctionCall(Buffer()))
    }
}
