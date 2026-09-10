#!/usr/bin/env python3
"""Replace the pinned Dashboard's Ubuntu transaction UI with Arch instructions.

The Go executable embeds the JavaScript asset. Keep its byte length unchanged
so embedded-file offsets and executable sections remain valid. Refuse a changed
vendor bundle rather than patching an unreviewed version.
"""
from pathlib import Path
import sys

TRANSACTION = b'qg=({children:e})=>{const[t,n]=v.useState(null),[r,s]=v.useState(""),{updateInProgress:i}=xi(),a=d=>{s(d||"An error occurred while updating your device."),n("error")},{mutate:o,isSuccess:u}=Qs({path:"/update_reboot",method:"POST",onError:a});return v.useEffect(()=>{i&&n("progress")},[i]),v.useEffect(()=>{t==="progress"&&!i&&o()},[t]),l.jsxs(l.Fragment,{children:[l.jsx(Bg,{open:t==="confirmation",onOpenChange:n,slotTrigger:e}),l.jsx(Wg,{open:t==="progress",onError:a,enableStream:u||i}),l.jsx(Gg,{open:t==="error",errorMessage:r})]})}'
GUIDANCE = b'qg=()=>l.jsxs("div",{className:"text-sm max-w-sm",role:"note",children:[l.jsxs("p",{children:["To update Arch packages, open a terminal and run ",l.jsx("code",{children:"omarchy update"}),"."]}),l.jsx("p",{children:"Firmware updates are handled separately."})]})'
DISABLED = b'l.jsx(te,{kind:"primary",color:"brand",disabled:!0,children:"Update"})'


def patch(data):
    for old, new, count in ((TRANSACTION, GUIDANCE, 1), (DISABLED, b'l.jsx(qg,{})', 2)):
        if data.count(old) != count or len(new) > len(old):
            raise ValueError('Dashboard update UI changed; review the pinned vendor bundle')
        data = data.replace(old, new.ljust(len(old)))
    return data


if __name__ == '__main__':
    path = Path(sys.argv[1])
    path.write_bytes(patch(path.read_bytes()))
