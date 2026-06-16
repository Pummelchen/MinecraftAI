/// QUIC Loss Detection and Congestion Control (RFC 9002)
///
/// Implements NewReno congestion control and loss detection with
/// PTO (Probe Timeout) based retransmission.

import Foundation
import PummelchenQuicCore
import PummelchenQuicCrypto

// MARK: - Sent Packet Info

/// Information about a sent packet for loss detection.
public struct SentPacket: Sendable {
    /// Packet number
    public let packetNumber: UInt64

    /// Time the packet was sent
    public let sentTime: Date

    /// Encoded size of the packet
    public let size: Int

    /// Encryption level
    public let level: EncryptionLevel

    /// Whether this packet is ack-eliciting
    public let ackEliciting: Bool

    /// Frames in this packet (for retransmission)
    public let frames: [Frame]

    /// Whether this packet has been acknowledged
    public var acknowledged: Bool = false

    public init(
        packetNumber: UInt64,
        sentTime: Date = Date(),
        size: Int,
        level: EncryptionLevel,
        ackEliciting: Bool = true,
        frames: [Frame] = []
    ) {
        self.packetNumber = packetNumber
        self.sentTime = sentTime
        self.size = size
        self.level = level
        self.ackEliciting = ackEliciting
        self.frames = frames
    }
}

// MARK: - RTT Estimation

/// RTT estimation using EWMA (RFC 9002 §5).
public final class RTTEstimator: @unchecked Sendable {
    /// Latest RTT sample
    public private(set) var latestRTT: TimeInterval = 0

    /// Smoothed RTT
    public private(set) var smoothedRTT: TimeInterval = 0.033 // 33ms initial

    /// RTT variation
    public private(set) var rttVar: TimeInterval = 0.0165 // smoothedRTT/2 initial

    /// Minimum RTT observed
    public private(set) var minRTT: TimeInterval = .infinity

    /// Whether we've received the first RTT sample
    private var hasSample = false

    public init() {}

    /// Update with a new RTT sample.
    public func update(sampleRTT: TimeInterval, ackDelay: TimeInterval = 0) {
        latestRTT = sampleRTT

        if !hasSample {
            // First sample
            smoothedRTT = sampleRTT
            rttVar = sampleRTT / 2
            minRTT = sampleRTT
            hasSample = true
            return
        }

        // Update minRTT
        if sampleRTT < minRTT { minRTT = sampleRTT }

        // Adjust for ack delay (RFC 9002 §5.3)
        let adjustedRTT: TimeInterval
        if sampleRTT > minRTT + ackDelay {
            adjustedRTT = sampleRTT - ackDelay
        } else {
            adjustedRTT = sampleRTT
        }

        // EWMA update (RFC 9002 §5.3)
        // rttvar = 3/4 * rttvar + 1/4 * |smoothed_rtt - adjusted_rtt|
        let absDiff = abs(smoothedRTT - adjustedRTT)
        rttVar = 0.75 * rttVar + 0.25 * absDiff

        // smoothed_rtt = 7/8 * smoothed_rtt + 1/8 * adjusted_rtt
        smoothedRTT = 0.875 * smoothedRTT + 0.125 * adjustedRTT
    }

    /// Probe Timeout = smoothedRTT + max(4*rttvar, 1ms)
    public var probeTimeout: TimeInterval {
        max(smoothedRTT + 4 * rttVar, 0.001)
    }
}

// MARK: - Congestion Controller

/// NewReno congestion controller (RFC 9002 §7).
public final class CongestionController: @unchecked Sendable {
    /// Congestion window in bytes
    public private(set) var congestionWindow: Int

    /// Bytes in flight
    public private(set) var bytesInFlight: Int = 0

    /// Slow start threshold
    public private(set) var ssthresh: Int = Int.max

    /// Minimum congestion window (2 × MSS)
    private let minimumWindow: Int

    /// Maximum segment size
    private let maxPacketSize: Int = 1200

    /// Congestion state
    public enum State: Sendable {
        case slowStart
        case congestionAvoidance
        case recovery
    }

    public private(set) var state: State = .slowStart

    /// Recovery start time
    private var recoveryStartTime: Date?

    public init(initialWindow: Int = 14720) { // ~10 packets
        self.congestionWindow = initialWindow
        self.minimumWindow = 2 * 1200
    }

    /// Called when a packet is sent.
    public func onPacketSent(bytesSent: Int) {
        bytesInFlight += bytesSent
    }

    /// Called when a packet is acknowledged.
    public func onPacketAcknowledged(bytesAcked: Int, rttEstimator: RTTEstimator) {
        bytesInFlight = max(0, bytesInFlight - bytesAcked)

        guard state != .recovery else { return }

        if state == .slowStart {
            // Slow start: increase by bytes acked
            congestionWindow += bytesAcked
            if congestionWindow >= ssthresh {
                state = .congestionAvoidance
            }
        } else {
            // Congestion avoidance: increase by ~1 MSS per RTT
            let increment = (maxPacketSize * bytesAcked) / congestionWindow
            congestionWindow += max(increment, 1)
        }
    }

    /// Called when packets are lost.
    public func onPacketsLost(lostBytes: Int) {
        bytesInFlight = max(0, bytesInFlight - lostBytes)

        // Enter recovery (only once per RTT)
        let now = Date()
        if let start = recoveryStartTime,
           now.timeIntervalSince(start) < 1.0 {
            return // Already in recovery for this RTT
        }

        recoveryStartTime = now
        state = .recovery

        // NewReno: ssthresh = max(cwnd/2, minimumWindow)
        ssthresh = max(congestionWindow / 2, minimumWindow)
        congestionWindow = ssthresh

        // After loss, transition to congestion avoidance on next ACK
        state = .congestionAvoidance
    }

    /// Called on persistent congestion (all packets in a window lost).
    public func onPersistentCongestion() {
        congestionWindow = minimumWindow
        ssthresh = congestionWindow
        state = .slowStart
    }

    /// Whether we can send more data.
    public var canSend: Bool {
        bytesInFlight < congestionWindow
    }

    /// Available send window.
    public var availableWindow: Int {
        max(0, congestionWindow - bytesInFlight)
    }
}

// MARK: - Loss Detector

/// Loss detection engine (RFC 9002 §6).
public final class LossDetector: @unchecked Sendable {
    /// Sent packets per encryption level.
    private var sentPackets: [EncryptionLevel: [SentPacket]] = [
        .initial: [],
        .handshake: [],
        .application: []
    ]

    /// Largest acknowledged packet number per level.
    private var largestAcked: [EncryptionLevel: UInt64] = [:]

    /// RTT estimator
    public let rtt = RTTEstimator()

    /// Congestion controller
    public let congestion = CongestionController()

    /// Time threshold multiplier for loss detection (9/8)
    private let timeThresholdMultiplier: Double = 9.0 / 8.0

    /// Packet threshold for loss detection
    private let packetThreshold: UInt64 = 3

    /// Timer for PTO
    public var ptoTimer: Date?

    /// PTO count (number of consecutive PTOs without ACK)
    public private(set) var ptoCount: Int = 0

    public init() {}

    /// Record a sent packet.
    public func onPacketSent(_ packet: SentPacket) {
        sentPackets[packet.level, default: []].append(packet)
        if packet.ackEliciting {
            congestion.onPacketSent(bytesSent: packet.size)
        }
    }

    /// Process an incoming ACK frame.
    /// Returns: (newly acked packets, lost packets)
    public func onAckReceived(
        ack: AckFrame,
        level: EncryptionLevel,
        receiveTime: Date = Date()
    ) -> (acked: [SentPacket], lost: [SentPacket]) {
        guard var packets = sentPackets[level] else { return ([], []) }

        var newlyAcked: [SentPacket] = []

        // Update largest acked
        let currentLargest = largestAcked[level] ?? 0
        if ack.largestAcknowledged > currentLargest {
            largestAcked[level] = ack.largestAcknowledged

            // RTT sample from largest newly acked
            if let idx = packets.firstIndex(where: { $0.packetNumber == ack.largestAcknowledged }) {
                let sentPacket = packets[idx]
                let rttSample = receiveTime.timeIntervalSince(sentPacket.sentTime)
                let ackDelay = Double(ack.ackDelay) / 1_000_000.0 // microseconds to seconds
                rtt.update(sampleRTT: rttSample, ackDelay: ackDelay)
            }
        }

        // Mark acknowledged packets
        // Build all acknowledged PN ranges from the AckFrame
        let pnRanges = ack.allAcknowledgedRanges
        for range in pnRanges {
            for pn in range {
                if let idx = packets.firstIndex(where: { $0.packetNumber == pn && !$0.acknowledged }) {
                    packets[idx].acknowledged = true
                    newlyAcked.append(packets[idx])
                    if packets[idx].ackEliciting {
                        congestion.onPacketAcknowledged(bytesAcked: packets[idx].size, rttEstimator: rtt)
                    }
                }
            }
        }

        // Detect lost packets
        let lost = detectLostPackets(level: level, packets: &packets)

        sentPackets[level] = packets.filter { !$0.acknowledged }

        // Reset PTO count on receiving an ACK
        ptoCount = 0

        return (newlyAcked, lost)
    }

    /// Detect lost packets based on packet number and time thresholds.
    private func detectLostPackets(level: EncryptionLevel, packets: inout [SentPacket]) -> [SentPacket] {
        guard let largest = largestAcked[level] else { return [] }

        let lossDelay = max(rtt.latestRTT, rtt.smoothedRTT) * timeThresholdMultiplier
        let now = Date()
        var lost: [SentPacket] = []

        for i in packets.indices {
            guard !packets[i].acknowledged else { continue }

            let pn = packets[i].packetNumber

            // Packet number threshold
            if largest > packetThreshold && pn <= largest - packetThreshold {
                lost.append(packets[i])
                if packets[i].ackEliciting {
                    congestion.onPacketsLost(lostBytes: packets[i].size)
                }
                continue
            }

            // Time threshold
            if now.timeIntervalSince(packets[i].sentTime) > lossDelay {
                lost.append(packets[i])
                if packets[i].ackEliciting {
                    congestion.onPacketsLost(lostBytes: packets[i].size)
                }
            }
        }

        return lost
    }

    /// Compute the PTO timeout.
    public func computePTO() -> TimeInterval {
        let pto = rtt.probeTimeout * TimeInterval(1 << min(ptoCount, 10))
        return pto
    }

    /// Called when a PTO fires (no ACK received in time).
    public func onPTOTimeout() {
        ptoCount += 1
    }

    /// Get all unacked packets for a level.
    public func unackedPackets(level: EncryptionLevel) -> [SentPacket] {
        return sentPackets[level]?.filter { !$0.acknowledged } ?? []
    }
}

// MARK: - ACK Frame Helper

/// Helper for ACK frame ranges.
extension AckFrame {
    /// All acknowledged packet number ranges (including the first block).
    ///
    /// The first block is [largest - firstAckRange .. largest].
    /// Additional blocks use the gap + rangeLength from ackRanges.
    /// Note: `firstAckRange` is computed from the structure — we use
    /// the first element of ackRanges as the first range if present,
    /// or just the largest PN alone.
    public var allAcknowledgedRanges: [ClosedRange<UInt64>] {
        var ranges: [ClosedRange<UInt64>] = []

        if ackRanges.isEmpty {
            // Just the largest acknowledged
            ranges.append(largestAcknowledged...largestAcknowledged)
            return ranges
        }

        // First block: the first AckRange gives us the first contiguous range
        // In QUIC ACK encoding:
        //   First ACK Range = first_ack_range field (not in ackRanges array)
        //   Additional ranges come from ackRanges
        //
        // Since our AckFrame stores additional ranges in ackRanges,
        // the first block is from (largest - implicit first range) to largest.
        // For simplicity, we treat the entire ackRanges as the gap/range pairs
        // starting after the largest PN.

        // The first range extends from some start to largestAcknowledged.
        // Without the explicit first_ack_range stored separately,
        // we compute from the gap structure.
        // For now: just include the largest PN as the first range,
        // then add additional ranges.
        ranges.append(largestAcknowledged...largestAcknowledged)

        var currentPN = largestAcknowledged
        for ar in ackRanges {
            // Skip gap + 2 packet numbers
            let gapEnd = currentPN >= ar.gap + 2 ? currentPN - ar.gap - 2 : 0
            let rangeStart = gapEnd >= ar.rangeLength ? gapEnd - ar.rangeLength : 0
            if rangeStart <= gapEnd {
                ranges.append(rangeStart...gapEnd)
            }
            currentPN = rangeStart
        }

        return ranges
    }
}
