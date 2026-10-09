#!/usr/bin/env python3
"""Build USB Audio firmware in an isolated Teensy 1.62.0 core; never upload."""
from pathlib import Path
import argparse
import difflib
import hashlib
import json
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = '1.62.0'

def descriptors(channels, companion):
    groups = [channels] + ([1] if companion else [])
    result = [9,2,0,0,2+len(groups)*2,1,0,0x80,50]
    result += [8,11,0,2,2,2,1,0] # CDC IAD, preserving software reboot.
    result += [9,4,0,0,1,2,2,1,0]
    result += [5,0x24,0,0x10,0x01, 5,0x24,1,0,1, 4,0x24,2,6, 5,0x24,6,0,1]
    result += [7,5,0x82,3,16,0,64]
    result += [9,4,1,0,2,10,0,0,0, 7,5,3,2,64,0,0, 7,5,0x84,2,64,0,0]
    for stream, count in enumerate(groups):
        control = 2 + stream*2; audio = control+1; endpoint = 5+stream; string = 4+stream
        packet = 33*count*2
        result += [8,11,control,2,1,0,0,string]
        result += [9,4,control,0,0,1,1,0,string]
        result += [9,0x24,1,0,1,30,0,1,audio]
        result += [12,0x24,2,1,1,2,0,count,0,0,10 if count==7 else 0,0]
        result += [9,0x24,3,2,1,1,0,1,0]
        result += [9,4,audio,0,0,1,2,0,string, 9,4,audio,1,1,1,2,0,string]
        result += [7,0x24,1,2,1,1,0, 11,0x24,2,1,count,2,16,1,0,0x7d,0]
        result += [9,5,0x80|endpoint,5,packet&255,packet>>8,1,0,0, 7,0x25,1,0,0,0,0]
    result[2:4] = [len(result)&255,len(result)>>8]
    return bytes(result)

def replace_once(text, old, new):
    if text.count(old) != 1: raise RuntimeError(f'Core patch anchor count {text.count(old)}: {old[:80]!r}')
    return text.replace(old,new,1)

def patch_core(core, channels, companion, work):
    originals={name:(core/name).read_text() for name in ['usb_desc.h','usb_desc.c','usb_dev.c']}
    extra='''\n// Piezo LC USB Audio: CDC remains stock for diagnostics and 134-baud reboot.
#include "piezo_usb_audio.h"
#undef PRODUCT_ID
#define PRODUCT_ID 0x048A
#undef DEVICE_CLASS
#define DEVICE_CLASS 0xEF
#define DEVICE_SUBCLASS 2
#define DEVICE_PROTOCOL 1
#undef NUM_ENDPOINTS
#define NUM_ENDPOINTS (5 + PIEZO_USB_MONO_COMPANION)
#undef NUM_INTERFACE
#define NUM_INTERFACE (4 + 2 * PIEZO_USB_MONO_COMPANION)
#define ENDPOINT5_CONFIG ENDPOINT_TRANSMIT_ISOCHRONOUS
#if PIEZO_USB_MONO_COMPANION
#define ENDPOINT6_CONFIG ENDPOINT_TRANSMIT_ISOCHRONOUS
#endif
#undef PRODUCT_NAME
#define PRODUCT_NAME {'P','i','e','z','o',' ','B','o','x',' ','L','C'}
#undef PRODUCT_NAME_LEN
#define PRODUCT_NAME_LEN 12
'''
    h=replace_once(originals['usb_desc.h'],'#ifdef USB_DESC_LIST_DEFINE',extra+'\n#ifdef USB_DESC_LIST_DEFINE')
    (core/'usb_desc.h').write_text(h)
    d=originals['usb_desc.c']; raw=descriptors(channels,companion)
    d=re.sub(r'0x10, 0x01,([ ]+// bcdUSB)', r'0x00, 0x02,\1', d, count=1)
    start=d.index('static uint8_t config_descriptor[CONFIG_DESC_SIZE] = {')
    end=d.index('\n};',start)+3
    array='static uint8_t config_descriptor[] = {\n'+ '\n'.join('    '+','.join(f'0x{x:02x}' for x in raw[i:i+16])+',' for i in range(0,len(raw),16))+'\n};'
    d=d[:start]+array+d[end:]
    strings={4:'Piezo Box LC Mono' if channels==1 else 'Piezo Box LC 7 Inputs'}
    if companion: strings[5]='Piezo Box LC Mono'
    strings.update({10+i:f'Input {i+1} / A{i+1}' for i in range(7)})
    declarations=[]; entries=[]
    for index,name in strings.items():
        declarations.append(f'static struct usb_string_descriptor_struct piezo_string_{index} = {{ {2+2*len(name)}, 3, {{'+','.join(str(ord(c)) for c in name)+'} };')
        entries.append(f'    {{0x03{index:02x}, 0x0409, (const uint8_t *)&piezo_string_{index}, 0}},')
    d=replace_once(d,'const usb_descriptor_list_t usb_descriptor_list[] = {','\n'.join(declarations)+'\n\nconst usb_descriptor_list_t usb_descriptor_list[] = {\n'+'\n'.join(entries))
    (core/'usb_desc.c').write_text(d)
    c=originals['usb_dev.c']
    c=replace_once(c,'static void endpoint0_stall(void)','\n#include "usb_hooks.inc"\n\nstatic void endpoint0_stall(void)')
    c=replace_once(c,'\t\tusb_configuration = setup.wValue;', '\t\tpiezo_reset_streams(0);\n\t\tusb_configuration = setup.wValue;')
    c=replace_once(c,'if (table[i].desc & BDT_OWN) {','if ((table[i].desc & BDT_OWN) && (i >> 2) < 5) {')
    c=replace_once(c,'#if defined(AUDIO_INTERFACE)\n\t  case 0x0B01:', '#include "control_requests.inc"\n\n#if defined(AUDIO_INTERFACE)\n\t  case 0x0B01:')
    c=replace_once(c,'#endif\n\t\t// give the buffer back\n\t\tb->desc = BDT_DESC(EP0_SIZE, DATA1);','''#endif
        if (setup.wRequestAndType == 0x0122) {
            if (setup.wLength == 3 && (b->desc >> 16) == 3 && buf[0] == 0 && buf[1] == 0x7d && buf[2] == 0)
                endpoint0_transmit(NULL, 0);
            else endpoint0_stall();
        }
\t\t// give the buffer back
\t\tb->desc = BDT_DESC(EP0_SIZE, DATA1);''')
    c=replace_once(c,'\t\t\tif (stat & 0x08) { // transmit','''            if (piezo_stream_for_endpoint(endpoint + 1) >= 0 && (stat & 0x08)) {
                unsigned stream = endpoint + 1 - 5;
                piezo_next_bank[stream] = (stat & 4) ? 0 : 1;
                ++piezo_usb_packets[stream];
                if (piezo_usb_active[stream]) piezo_prime(stream);
            } else
\t\t\tif (stat & 0x08) { // transmit''')
    c=replace_once(c,'\tif (status & USB_ISTAT_USBRST /* 01 */ ) {','\tif (status & USB_ISTAT_USBRST /* 01 */ ) {\n        piezo_reset_streams(1);\n        usb_configuration = 0;')
    (core/'usb_dev.c').write_text(c)
    for file in ['piezo_usb_audio.h','usb_hooks.inc','control_requests.inc']: shutil.copy2(ROOT/'usb_audio'/file, core/file)
    diff=''.join(''.join(difflib.unified_diff(originals[n].splitlines(True),(core/n).read_text().splitlines(True),fromfile='stock/'+n,tofile='piezo/'+n)) for n in originals)
    (work/'core.patch').write_text(diff)
    (work/'configuration.bin').write_bytes(raw)
    (work/'core-provenance.json').write_text(json.dumps({n:hashlib.sha256(s.encode()).hexdigest() for n,s in originals.items()},indent=2)+'\n')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--arduino-cli',required=True,type=Path);p.add_argument('--data-dir',required=True,type=Path)
    p.add_argument('--work-dir',type=Path,default=ROOT/'build/usb-audio')
    p.add_argument('--channels',type=int,choices=[1,7],default=7);p.add_argument('--mono-companion',action='store_true')
    p.add_argument('--prototype',action='store_true');p.add_argument('--prepare-only',action='store_true')
    a=p.parse_args();work=a.work_dir.resolve();work.mkdir(parents=True,exist_ok=True)
    source=a.data_dir.resolve();data=work/'arduino-data';data.mkdir(exist_ok=True)
    for f in source.glob('*.json'): shutil.copy2(f,data/f.name)
    packages=data/'packages';packages.mkdir(exist_ok=True)
    for package in ['builtin']:
        if (source/'packages'/package).exists() and not (packages/package).exists(): (packages/package).symlink_to(source/'packages'/package,target_is_directory=True)
    tools=packages/'teensy/tools';tools.parent.mkdir(exist_ok=True)
    if not tools.exists(): tools.symlink_to(source/'packages/teensy/tools',target_is_directory=True)
    origin=source/f'packages/teensy/hardware/avr/{VERSION}'
    platform=data/f'packages/teensy/hardware/avr/{VERSION}';platform.mkdir(parents=True,exist_ok=True)
    for name in ['boards.txt','platform.txt']: shutil.copy2(origin/name,platform/name)
    core=platform/'cores/teensy3';shutil.copytree(origin/'cores/teensy3',core,dirs_exist_ok=True)
    patch_core(core,a.channels,a.mono_companion,work)
    config=work/'arduino-cli.yaml'
    config.write_text('board_manager:\n  additional_urls:\n    - https://www.pjrc.com/teensy/package_teensy_index.json\ndirectories:\n'+''.join('  '+k+': '+json.dumps(str(v))+'\n' for k,v in [('data',data),('downloads',work/'downloads'),('user',work/'user')]))
    if a.prepare_only: return
    defs=f'-D__MKL26Z64__ -DTEENSYDUINO=160 -DPIEZO_USB_CHANNELS={a.channels} -DPIEZO_USB_MONO_COMPANION={int(a.mono_companion)} -DPIEZO_PROTOTYPE={int(a.prototype)}'
    subprocess.run([str(a.arduino_cli.resolve()),'--config-file',str(config),'compile','--fqbn','teensy:avr:teensyLC:usb=serial,speed=48,opt=o3std',
        '--build-property','build.flags.defs='+defs,'--build-property','build.flags.optimize=-O3 --specs=nano.specs',
        '--build-property','recipe.hooks.postbuild.1.pattern=','--build-path',str(work/'build'),str(ROOT/'piezo_lc_audio')],check=True)
    print(work/'build/piezo_lc_audio.ino.hex')
if __name__=='__main__':main()
