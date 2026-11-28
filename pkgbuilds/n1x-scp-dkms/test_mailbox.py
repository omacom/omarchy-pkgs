"""Compile the production mailbox and descriptor paths with fake MMIO, no hardware."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent

HARNESS = r'''#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint16_t __le16;
typedef size_t resource_size_t;
#define __iomem
#define BIT(n) (1U << (n))
#define round_up(n,a) (((n)+(a)-1)&~((a)-1))
#define cpu_to_le16(n) (n)
#define le16_to_cpu(n) (n)
#define wmb() ((void)0)
#define module_param(...)
#define MODULE_PARM_DESC(...)
#define DEFINE_SHOW_ATTRIBUTE(...)
struct mutex { bool held; };
struct seq_file { void *private; unsigned printed; };
static int mode, sent, acknowledged;
static bool bad_seen;
static unsigned char mmio[2][0x110];
static void *active;
static int mutex_lock_interruptible(struct mutex *m)
{ assert(!m->held); m->held = true; return 0; }
static void mutex_unlock(struct mutex *m);
static u32 ioread32(void *p) { u32 v; memcpy(&v,p,4); return v; }
static void memcpy_toio(void *d,const void *s,size_t n) { memcpy(d,s,n); }
static void memcpy_fromio(void *d,const void *s,size_t n) { memcpy(d,s,n); }
static void iowrite32(u32 v,void *p) {
 assert(v==1);
 if(p==mmio[0]+0x100) sent++;
 else { assert(p==mmio[1]+0x10c); acknowledged++; }
}
static int poll_reply(void);
#define readl_poll_timeout(addr,status,cond,delay,timeout) \
 ((status)=1, assert((addr)==mmio[1]+0x104), assert(cond), poll_reply())
static void seq_printf(struct seq_file *s,const char *fmt,...) { s->printed++; }
static void seq_putc(struct seq_file *s,char c) { s->printed++; }
'''

TAIL = r'''static void mutex_unlock(struct mutex *m)
{
 struct n1x_scp *scp=active;
 assert(m->held);
 /* A waiting caller can enter as soon as this returns. */
 if(bad_seen) assert(scp->mailbox_poisoned);
 m->held=false;
}
static int poll_reply(void)
{
 struct n1x_scp_message *q=(void *)mmio[0], r={0};
 struct n1x_scp *scp=active;
 assert(scp->query_lock.held);
 r.token=q->token; r.command=q->command;
 if(q->command==0x25) { r.length=1; r.payload[0]=2; }
 if(q->command==0x26) { assert(q->length==1 && q->payload[0]==1); r.length=121; r.payload[0]=1; }
 if(mode==1) { r.token++; bad_seen=true; }
 if(mode==2) { r.command++; bad_seen=true; }
 if(mode==3) { r.length=249; bad_seen=true; }
 if(mode==4) { bad_seen=true; return -ETIMEDOUT; }
 if(mode==5 && q->command==0x25) { r.payload[0]=3; bad_seen=true; }
 if(mode==6 && q->command==0x25) { r.length=0; bad_seen=true; }
 if(mode==7 && q->command==0x26) { r.length=120; bad_seen=true; }
 if(mode==8 && q->command==0x26) { r.payload[0]=0; bad_seen=true; }
 if(mode==9 && q->command==0x25) { r.length=2; bad_seen=true; }
 if(mode==10 && q->command==0x26) { r.length=122; bad_seen=true; }
 memcpy(mmio[1],&r,sizeof(r));
 return 0;
}
int main(int argc,char **argv)
{
 assert(argc==2); mode=atoi(argv[1]);
 struct n1x_scp scp={.mailbox={mmio[0],mmio[1]}};
 struct seq_file seq={.private=&scp};
 struct n1x_scp_message reply;
 active=&scp; enable_mailbox=true;
 int ret=n1x_scp_sensors_show(&seq,NULL);
 if(!mode) { assert(!ret && !scp.mailbox_poisoned && sent==2 && acknowledged==2); return 0; }
 assert(ret==(mode==4 ? -ETIMEDOUT : -EPROTO));
 assert(scp.mailbox_poisoned && !scp.query_lock.held);
 int before=sent;
 assert(acknowledged==((mode==7 || mode==8 || mode==10) ? 1 : 0));
 assert(n1x_scp_query(&scp,0,NULL,0,&reply)==-ENOTRECOVERABLE);
 assert(sent==before);
 assert(n1x_scp_sensors_show(&seq,NULL)==-ENOTRECOVERABLE && sent==before);
 return 0;
}
'''


class MailboxTests(unittest.TestCase):
    def test_mailbox_guards_and_poison_before_unlock(self):
        source = (ROOT / "n1x_scp.c").read_text()
        definitions = source[source.index("#define N1X_LOG_OFFSET"):
                             source.index("static int n1x_scp_version_show")]
        sensors = source[source.index("static int n1x_scp_sensors_show"):
                         source.index("static int n1x_log_header")]
        with tempfile.TemporaryDirectory() as directory:
            cfile, binary = Path(directory) / "mailbox.c", Path(directory) / "mailbox"
            cfile.write_text(HARNESS + definitions + sensors + TAIL)
            subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-parameter", "-fsanitize=address,undefined",
                            "-fno-omit-frame-pointer", "-fno-pie", "-no-pie",
                            str(cfile), "-o", str(binary)], check=True)
            cases = ["valid", "token mismatch", "command mismatch", "oversized",
                     "timeout", "count value", "count short", "descriptor short",
                     "descriptor slot", "count long", "descriptor long"]
            for mode, name in enumerate(cases):
                with self.subTest(case=name):
                    subprocess.run([str(binary), str(mode)], check=True)


if __name__ == "__main__":
    unittest.main()
