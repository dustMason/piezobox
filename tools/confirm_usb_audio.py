#!/usr/bin/env python3
"""Confirm a prototype's serial recovery interface; optionally save its status."""
import argparse,json,time
from pathlib import Path
import serial
from serial.tools import list_ports
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True,help='USB serial number of the target Teensy');p.add_argument('--out',type=Path);a=p.parse_args()
end=time.monotonic()+12
while time.monotonic()<end:
    for device in list_ports.comports():
        if device.vid!=0x16c0 or device.serial_number!=a.serial:continue
        try:
            with serial.Serial(device.device,115200,timeout=.3,write_timeout=1) as s:
                s.write(b'\nINFO\n');info=s.readline().decode(errors='replace').strip()
                if not info.startswith('PZUA1'):continue
                s.write(b'CONFIRM\n');response=s.readline().decode().strip()
                if response!='OK':continue
                s.write(b'STATUS\n');status=json.loads(s.readline())
                print(device.device,info);print(json.dumps(status,indent=2))
                if a.out:a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(status,indent=2)+'\n')
                raise SystemExit(0)
        except (OSError,serial.SerialException,ValueError):pass
    time.sleep(.25)
raise SystemExit('No USB Audio serial interface confirmed; prototype recovery timer remains armed.')
