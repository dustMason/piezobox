#!/usr/bin/env python3
"""Verify exact low-level PCM patterns through macOS's built-in USB Audio driver."""
import argparse,json,subprocess
from pathlib import Path
import serial
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--port',required=True);p.add_argument('--uid',required=True)
p.add_argument('--channels',type=int,choices=[1,7],default=7);p.add_argument('--seconds',type=int,default=30)
p.add_argument('--out',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
with serial.Serial(a.port,115200,timeout=1,write_timeout=2) as device:
    device.write(b'CONFIRM\n');assert device.readline().strip()==b'OK'
    try:
        device.write(b'TEST_ON\n');assert device.readline().strip()==b'OK'
        result=subprocess.run([str(root/'build/usb-audio-probe'),a.uid,str(a.seconds),'32000',str(a.channels),'pattern'],capture_output=True,text=True)
        print(result.stdout,flush=True)
        if result.stderr:print(result.stderr,flush=True)
        device.write(b'STATUS\n');status=json.loads(device.readline())
        report={'host':json.loads(result.stdout.strip().splitlines()[-1]),'device':status,'host_exit_code':result.returncode}
    finally:
        device.write(b'TEST_OFF\n');assert device.readline().strip()==b'OK'
    device.write(b'STATUS\n');report['restored']=json.loads(device.readline())
a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
raise SystemExit(result.returncode)
