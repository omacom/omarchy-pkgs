#!/usr/bin/env python3
"""One-shot contrast focus using the rear lens's existing V4L2 control."""
from pathlib import Path
import subprocess, time
import cv2
lens = next('/dev/' + p.name for p in Path('/sys/class/video4linux').glob('v4l-subdev*') if 'dw9714' in (p/'name').read_text())
c = cv2.VideoCapture('/dev/video1', cv2.CAP_V4L2)
c.set(cv2.CAP_PROP_FRAME_WIDTH,1280); c.set(cv2.CAP_PROP_FRAME_HEIGHT,720)
def measure(position):
    subprocess.run(['v4l2-ctl','-d',lens,f'--set-ctrl=focus_absolute={position}'],check=True)
    time.sleep(.15)
    for _ in range(5): ok,frame=c.read()
    if not ok: raise RuntimeError('No rear camera frame')
    gray=cv2.cvtColor(frame,cv2.COLOR_BGR2GRAY)
    gray=cv2.medianBlur(gray,5)
    crop=gray[180:540,320:960]
    score=float(cv2.Laplacian(crop,cv2.CV_64F).var())
    print(position,round(score,3),flush=True)
    return score
try:
    deadline=time.monotonic()+4
    while time.monotonic()<deadline:
        ok,frame=c.read()
        if ok and frame.max()>10 and frame.std()>.5: break
    else: raise RuntimeError('Rear camera did not start')
    scores={p:measure(p) for p in range(0,801,100)}
    best=max(scores,key=scores.get)
    scores.update({p:measure(p) for p in range(max(0,best-80),min(1024,best+81),20)})
    best=max(scores,key=scores.get)
    subprocess.run(['v4l2-ctl','-d',lens,f'--set-ctrl=focus_absolute={best}'],check=True)
    print('Focus position:',best)
finally: c.release()
