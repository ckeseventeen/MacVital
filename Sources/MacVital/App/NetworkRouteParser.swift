import Darwin
import Foundation

struct NetworkByteCounters: Equatable {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
}

/// Parses the mixed message stream returned by `NET_RT_IFLIST2`.
///
/// All route messages share only their first four bytes. Address records are
/// shorter than `if_msghdr`, so advancing the stream as though every record
/// were an interface header stops immediately after loopback on a normal Mac.
enum NetworkRouteParser {
    static func parse(_ raw: UnsafeRawBufferPointer) -> NetworkByteCounters {
        var counters = NetworkByteCounters()
        var offset = 0

        while offset + 4 <= raw.count {
            let messageLength = Int(
                raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            )
            let messageType = raw[offset + 3]
            guard messageLength >= 4, offset + messageLength <= raw.count else { break }

            if messageType == RTM_IFINFO2,
               messageLength >= MemoryLayout<if_msghdr2>.size {
                let header = raw.loadUnaligned(
                    fromByteOffset: offset,
                    as: if_msghdr2.self
                )
                let data = header.ifm_data
                if data.ifi_type != UInt8(IFT_LOOP) {
                    counters.bytesIn &+= data.ifi_ibytes
                    counters.bytesOut &+= data.ifi_obytes
                }
            }

            offset += messageLength
        }

        return counters
    }
}
