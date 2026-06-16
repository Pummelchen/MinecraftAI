import Testing
import Foundation
@testable import PummelchenQuic
@testable import PummelchenQuicCore

// MARK: - Stream ID Tests

struct StreamIDTests {
    @Test func streamIDClassification() {
        // Client bidi: 0, 4, 8...
        #expect(StreamID.isClientInitiated(0))
        #expect(StreamID.isBidirectional(0))
        #expect(StreamID.streamType(0) == .clientBidi)

        // Server bidi: 1, 5, 9...
        #expect(StreamID.isServerInitiated(1))
        #expect(StreamID.isBidirectional(1))
        #expect(StreamID.streamType(1) == .serverBidi)

        // Client uni: 2, 6, 10...
        #expect(StreamID.isClientInitiated(2))
        #expect(StreamID.isUnidirectional(2))
        #expect(StreamID.streamType(2) == .clientUni)

        // Server uni: 3, 7, 11...
        #expect(StreamID.isServerInitiated(3))
        #expect(StreamID.isUnidirectional(3))
        #expect(StreamID.streamType(3) == .serverUni)
    }
}

// MARK: - Receive Buffer Tests

struct ReceiveBufferTests {
    @Test func receiveInOrder() throws {
        let buf = ReceiveBuffer()
        try buf.insert(offset: 0, data: Data("Hello".utf8))
        try buf.insert(offset: 5, data: Data(" World".utf8))

        let data = buf.read()
        #expect(String(data: data!, encoding: .utf8) == "Hello World")
    }

    @Test func receiveOutOfOrder() throws {
        let buf = ReceiveBuffer()
        try buf.insert(offset: 5, data: Data("World".utf8))

        // Can't read yet — gap at offset 0
        #expect(buf.read() == nil)

        try buf.insert(offset: 0, data: Data("Hello".utf8))

        let data = buf.read()
        #expect(String(data: data!, encoding: .utf8) == "HelloWorld")
    }

    @Test func receiveDuplicate() throws {
        let buf = ReceiveBuffer()
        try buf.insert(offset: 0, data: Data("Hello".utf8))
        try buf.insert(offset: 0, data: Data("Hello".utf8)) // duplicate

        let data = buf.read()
        #expect(data?.count == 5)
    }

    @Test func receiveOverlapping() throws {
        let buf = ReceiveBuffer()
        try buf.insert(offset: 0, data: Data("Hel".utf8))
        try buf.insert(offset: 2, data: Data("llo".utf8)) // overlaps at offset 2-3

        let data = buf.read()
        #expect(String(data: data!, encoding: .utf8) == "Hello")
    }
}

// MARK: - Send Buffer Tests

struct SendBufferTests {
    @Test func sendAndAck() throws {
        let buf = SendBuffer()
        try buf.write(Data("test data".utf8))

        #expect(buf.hasDataToSend)
        let chunk = buf.readToSend(maxSize: 100)
        #expect(chunk != nil)
        #expect(chunk?.offset == 0)
        #expect(chunk?.data.count == 9)

        buf.acknowledge(offset: 0, length: 9)
        #expect(buf.retransmitAll().isEmpty)
    }

    @Test func sendWindow() throws {
        let buf = SendBuffer(maxOffset: 10)
        try buf.write(Data("12345678".utf8)) // 8 bytes

        #expect(buf.window == 2) // 10 - 8 = 2
    }
}

// MARK: - Stream Manager Tests

struct StreamManagerTests {
    @Test func openBidiStreams() {
        let mgr = StreamManager(isClient: true)
        let s1 = mgr.openBidirectionalStream()
        let s2 = mgr.openBidirectionalStream()

        #expect(s1?.streamID == 0)
        #expect(s2?.streamID == 4)
    }

    @Test func openUniStreams() {
        let mgr = StreamManager(isClient: true)
        let s1 = mgr.openUnidirectionalStream()
        let s2 = mgr.openUnidirectionalStream()

        #expect(s1?.streamID == 2)
        #expect(s2?.streamID == 6)
    }

    @Test func serverStreams() {
        let mgr = StreamManager(isClient: false)
        let s1 = mgr.openBidirectionalStream()
        #expect(s1?.streamID == 1) // server-initiated bidi
    }

    @Test func getOrCreateIncoming() {
        let mgr = StreamManager(isClient: true)
        let s = mgr.getOrCreateStream(for: 1) // server-initiated bidi
        #expect(s.streamID == 1)
        #expect(s.recvBuffer != nil)
        #expect(s.sendBuffer != nil)
    }
}

// MARK: - RTT Estimator Tests

struct RTTEstimatorTests {
    @Test func rttFirstSample() {
        let rtt = RTTEstimator()
        rtt.update(sampleRTT: 0.1)

        #expect(rtt.smoothedRTT == 0.1)
        #expect(abs(rtt.rttVar - 0.05) < 0.001)
        #expect(rtt.minRTT == 0.1)
    }

    @Test func rttConvergence() {
        let rtt = RTTEstimator()
        rtt.update(sampleRTT: 0.1)
        rtt.update(sampleRTT: 0.1)
        rtt.update(sampleRTT: 0.1)

        #expect(abs(rtt.smoothedRTT - 0.1) < 0.01)
    }

    @Test func probeTimeout() {
        let rtt = RTTEstimator()
        rtt.update(sampleRTT: 0.1)
        #expect(rtt.probeTimeout > 0.1) // PTO > SRTT
    }
}

// MARK: - Congestion Controller Tests

struct CongestionControllerTests {
    @Test func slowStartGrowth() {
        let cc = CongestionController()
        let rtt = RTTEstimator()
        let initialWindow = cc.congestionWindow

        cc.onPacketSent(bytesSent: 1200)
        cc.onPacketAcknowledged(bytesAcked: 1200, rttEstimator: rtt)

        #expect(cc.congestionWindow == initialWindow + 1200)
    }

    @Test func lossReducesWindow() {
        let cc = CongestionController()
        cc.onPacketSent(bytesSent: 5000)
        let windowBefore = cc.congestionWindow

        cc.onPacketsLost(lostBytes: 1200)

        #expect(cc.congestionWindow < windowBefore)
    }

    @Test func canSendWhenWindowAvailable() {
        let cc = CongestionController()
        #expect(cc.canSend)
        #expect(cc.availableWindow > 0)
    }
}
