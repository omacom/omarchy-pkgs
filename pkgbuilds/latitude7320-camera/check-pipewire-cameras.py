#!/usr/bin/python
"""Verify portal-facing camera names, real frames and release after use."""
import json, subprocess, time
from pathlib import Path
sensors={'front':Path('/sys/bus/i2c/devices/i2c-OVTI5678:00/power/runtime_status'),
         'rear':Path('/sys/bus/i2c/devices/i2c-OVTI8856:00/power/runtime_status')}
def idle():
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        if all(p.read_text().strip()=='suspended' for p in sensors.values()):return
        time.sleep(.05)
    raise AssertionError({n:p.read_text().strip() for n,p in sensors.items()})
objects=json.loads(subprocess.check_output(['pw-dump']))
nodes={o['info']['props']['node.description']:o['info']['props']['object.serial'] for o in objects
       if o.get('info',{}).get('props',{}).get('media.class')=='Video/Source'}
assert set(nodes)=={'Latitude Front Camera','Latitude Rear Camera'}, nodes
print('PASS PipeWire camera names',list(nodes),flush=True)
idle()
for name,serial in nodes.items():
    result=subprocess.run(['gst-launch-1.0','-q','pipewiresrc','target-object='+str(serial),'num-buffers=30',
        '!','video/x-raw,format=YUY2,width=1280,height=720','!','filesink','location=/dev/stdout'],
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8)
    assert result.returncode==0,result.stderr.decode()
    assert len(result.stdout)>=1280*720*2, len(result.stdout)
    # Any non-black luminance in the last frame proves the physical source woke.
    frame=result.stdout[-1280*720*2:]
    assert max(frame[::2])>32, 'Only black standby frames'
    idle()
    print('PASS',name,'live through PipeWire; both sensors suspended afterward',flush=True)
