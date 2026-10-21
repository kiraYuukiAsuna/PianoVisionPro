#!/usr/bin/env python3
"""Write an original, tiny two-track MIDI exercise with a tempo change."""
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
def vlq(value):
    result = [value & 127]
    while value >> 7:
        value >>= 7
        result.insert(0, (value & 127) | 128)
    return bytes(result)
def track(events):
    data, last = bytearray(), 0
    for tick, message in sorted(events, key=lambda e: e[0]):
        data.extend(vlq(tick - last) + message)
        last = tick
    data.extend(b'\x00\xff\x2f\x00')
    return b'MTrk' + struct.pack('>I', len(data)) + data

melody = [(0, b'\xff\x03\x0eMVP right hand'), (0, b'\xff\x51\x03\x07\xa1\x20'), (0, b'\xff\x58\x04\x04\x02\x18\x08'), (3840, b'\xff\x51\x03\x0a\x2c\x2b')]
for index, pitch in enumerate([60, 62, 64, 65, 67, 69, 71, 72, 72, 71, 69, 67, 65, 64, 62, 60]):
    tick = 960 + index * 480
    melody.extend([(tick, bytes([0x90, pitch, 84])), (tick + 400, bytes([0x80, pitch, 0]))])
bass = [(0, b'\xff\x03\x0dMVP left hand')]
for tick, pitches in [(960, [48, 52, 55]), (2880, [45, 48, 52]), (4800, [41, 45, 48]), (6720, [43, 47, 50])]:
    for pitch in pitches:
        bass.extend([(tick, bytes([0x91, pitch, 68])), (tick + 1700, bytes([0x81, pitch, 0]))])
data = b'MThd' + struct.pack('>IHHH', 6, 1, 2, 480) + track(melody) + track(bass)
for path in [ROOT / 'Samples/FirstSteps.mid', ROOT / 'Apps/PianoVision/Resources/FirstSteps.mid']:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
print(f"Generated original exercise ({len(data)} bytes)")
