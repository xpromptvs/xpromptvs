#!/usr/bin/env python3
"""Independent fast-data wire vectors; no product implementation imported."""
import json, struct
from pathlib import Path
root = Path(__file__).resolve().parent.parent
generation = bytes(range(16))
cases = []
for kind, stream, value, payload in [(1,0,0,b'hello'),(1,2,9007199254740993,b'x'),(1,1,4,bytes(8192)),(2,0,2**64-1,b''),(3,1,123,b''),(4,2,123,b'')]:
    wire = bytes([1,kind])+generation+bytes([stream])+struct.pack('>Q',value)
    if kind == 1: wire += struct.pack('>H',len(payload))+payload
    cases.append(dict(kind=kind,stream=stream,value=str(value),payload=payload.hex(),wire=wire.hex()))
base=bytes.fromhex(cases[0]['wire'])
bad=[b'',base[:18],bytes([2])+base[1:],base[:1]+b'\x09'+base[2:],base[:18]+b'\x03'+base[19:],base+b'x',base[:-1],base[:27]+struct.pack('>H',8193)+bytes(8193)]
(root/'protocol/fixtures/fast-data-vectors.json').write_text(json.dumps(dict(generation=generation.hex(),valid=cases,invalid=[x.hex() for x in bad]),indent=2)+'\n')
# Deterministic delivery trace: the oracle is the known framed messages, not either engine.
framed=struct.pack('>I',5)+b'hello'+struct.pack('>I',5)+b'world'
steps=[]
for offset,payload,want,at in [(5,framed[5:],[],0),(0,framed[:5],['68656c6c6f','776f726c64'],18),(0,framed,[],18)]:
    wire=bytes([1,1])+generation+b'\0'+struct.pack('>QH',offset,len(payload))+payload
    steps.append(dict(wire=wire.hex(),delivered=want,next=str(at)))
(root/'protocol/fixtures/fast-delivery-traces.json').write_text(json.dumps(dict(generation=generation.hex(),steps=steps),indent=2)+'\n')
