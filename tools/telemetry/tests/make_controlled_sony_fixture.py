"""Create an artificial metadata-only MP4 fixture; contains no camera recording or picture.

Two Sony-style RTMD packets test parsing, clock units, rad/s flags, factory bias and axes.
This file must never be used as evidence that a real camera clip contains gyro data.
"""
from pathlib import Path
import struct


def pack(fmt, *values): return struct.pack('>' + fmt, *values)
def box(name, data): return pack('I', len(data) + 8) + name.encode() + data
def full(name, data, flags=0): return box(name, pack('I', flags) + data)
def tag(number, data): return pack('HH', number, len(data)) + data


def packet(values):
    return pack('H', 28) + bytes(26) + b''.join([
        tag(0xe435, pack('i', 1000)),             # sensor samples per second
        tag(0xe436, pack('i', 1_000_000)),        # clock ticks per second
        tag(0xe437, pack('i', -1000)),            # first reading 1 ms before frame
        tag(0xe438, b'\x01'),                    # scale refers to radians, not degrees
        tag(0xe439, pack('f', 10)),              # ten raw LSB per rad/s
        tag(0xe43d, pack('hhh', 10, 20, 30)),    # factory zero-rate offset, raw LSB
        tag(0xe43e, pack('H', 0x8000)),          # factory offset valid
        tag(0xe43b, pack('ii', len(values), 6) + b''.join(pack('hhh', *v) for v in values))])


def main():
    samples = [packet([(100, 200, 300), (110, 210, 310)]), packet([(120, 220, 320), (130, 230, 330)])]
    ftyp = box('ftyp', b'isom' + pack('I', 512) + b'isomiso2mp41')
    marker = box('free', b'BIRDLOCK CONTROLLED TEST FIXTURE; manufacturer="Sony" modelName="ControlledTelemetryFixture"')
    offset = len(ftyp) + len(marker) + 8
    mdat = box('mdat', b''.join(samples))
    matrix = pack('9I', 65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824)
    mvhd = full('mvhd', pack('4I', 0, 0, 1000, 20) + pack('IHH', 65536, 256, 0) + bytes(8) + matrix + bytes(24) + pack('I', 2))
    tkhd = full('tkhd', pack('5I', 0, 0, 1, 0, 20) + bytes(8) + pack('hhhh', 0, 0, 0, 0) + matrix + pack('II', 0, 0), flags=3)
    mdhd = full('mdhd', pack('4IHH', 0, 0, 1000, 20, 0x55c4, 0))
    hdlr = full('hdlr', pack('I', 0) + b'meta' + bytes(12) + b'Controlled telemetry\0')
    stsd = full('stsd', pack('I', 1) + box('rtmd', bytes(6) + pack('H', 1) + bytes(20)))
    stts = full('stts', pack('III', 1, 2, 10))
    stsc = full('stsc', pack('IIII', 1, 1, 2, 1))
    stsz = full('stsz', pack('II', 0, 2) + b''.join(pack('I', len(s)) for s in samples))
    stco = full('stco', pack('II', 1, offset))
    stbl = box('stbl', stsd + stts + stsc + stsz + stco)
    dinf = box('dinf', full('dref', pack('I', 1) + full('url ', b'', flags=1)))
    minf = box('minf', full('nmhd', b'') + dinf + stbl)
    moov = box('moov', mvhd + box('trak', tkhd + box('mdia', mdhd + hdlr + minf)))
    destination = Path(__file__).parent / 'fixtures/controlled-sony-units.mp4'
    destination.write_bytes(ftyp + marker + mdat + moov)
    print('Wrote artificial metadata fixture:', destination)


if __name__ == '__main__': main()
