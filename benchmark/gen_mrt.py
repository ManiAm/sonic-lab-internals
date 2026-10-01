#!/usr/bin/env python3
"""Generate MRT TABLE_DUMPv2 file with synthetic IPv4/24 routes for GoBGP injection.

Usage:
    python3 gen_mrt.py [count] [nexthop] [origin_as] [outfile]

Examples:
    python3 gen_mrt.py 100000 10.0.0.57 65432 routes_100k.mrt
    python3 gen_mrt.py 10000 10.0.0.57 65432 routes_10k.mrt
    python3 gen_mrt.py 200000 10.0.0.57 65432 routes_200k.mrt

The generated file can be loaded into GoBGP with:
    gobgp mrt inject global routes_100k.mrt --no-ipv6
"""
import struct
import socket
import time
import sys
import os


def ip_to_bytes(ip):
    return socket.inet_aton(ip)


def write_mrt_header(f, msg_type, subtype, length, timestamp=None):
    if timestamp is None:
        timestamp = int(time.time())
    f.write(struct.pack('!IHH I', timestamp, msg_type, subtype, length))


def create_bgp_path_attr(nexthop_ip, origin_as):
    """Create minimal BGP path attributes: ORIGIN, AS_PATH, NEXT_HOP."""
    attrs = b''
    # ORIGIN: IGP (0)
    attrs += struct.pack('!BBB B', 0x40, 1, 1, 0)
    # AS_PATH: AS_SEQUENCE [origin_as]
    as_path_val = struct.pack('!BB I', 2, 1, origin_as)
    attrs += struct.pack('!BBB', 0x40, 2, len(as_path_val)) + as_path_val
    # NEXT_HOP
    nh = ip_to_bytes(nexthop_ip)
    attrs += struct.pack('!BBB', 0x40, 3, 4) + nh
    return attrs


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
    nexthop = sys.argv[2] if len(sys.argv) > 2 else "10.0.0.57"
    origin_as = int(sys.argv[3]) if len(sys.argv) > 3 else 65432
    outfile = sys.argv[4] if len(sys.argv) > 4 else "routes_100k.mrt"

    path_attrs = create_bgp_path_attr(nexthop, origin_as)

    with open(outfile, 'wb') as f:
        # PEER_INDEX_TABLE (MRT type 13, subtype 1)
        collector_id = ip_to_bytes("192.168.221.12")
        view_name = b''
        peer_count = 1
        peer_entry = (
            struct.pack('!B', 0)
            + ip_to_bytes("192.168.221.12")
            + ip_to_bytes("192.168.221.12")
            + struct.pack('!I', origin_as)
        )

        pit_data = (
            collector_id
            + struct.pack('!H', len(view_name))
            + view_name
            + struct.pack('!H', peer_count)
            + peer_entry
        )
        write_mrt_header(f, 13, 1, len(pit_data))
        f.write(pit_data)

        # RIB_IPV4_UNICAST entries (MRT type 13, subtype 2)
        generated = 0
        for first_octet in range(10, 200):
            for second_octet in range(0, 256):
                for third_octet in range(0, 256):
                    if generated >= count:
                        break

                    prefix_bytes = ip_to_bytes(
                        f"{first_octet}.{second_octet}.{third_octet}.0"
                    )[:3]

                    # RIB entry: seq_num + prefix_len + prefix + entry_count + rib_entry
                    seq_bytes = struct.pack('!I', generated)
                    prefix_len_byte = struct.pack('!B', 24)
                    entry_count = struct.pack('!H', 1)
                    rib_entry = (
                        struct.pack('!H I H', 0, int(time.time()), len(path_attrs))
                        + path_attrs
                    )

                    rib_data = (
                        seq_bytes + prefix_len_byte + prefix_bytes
                        + entry_count + rib_entry
                    )
                    write_mrt_header(f, 13, 2, len(rib_data))
                    f.write(rib_data)

                    generated += 1
                if generated >= count:
                    break
            if generated >= count:
                break

    size = os.path.getsize(outfile)
    print(f"Generated {generated} routes in MRT format: {outfile}", file=sys.stderr)
    print(f"File size: {size / 1024 / 1024:.1f} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
