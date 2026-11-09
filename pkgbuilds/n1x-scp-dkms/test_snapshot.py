"""Adapted from upstream PR3 tests/test_platform_resources.py (GPL-2.0-only)."""
from pathlib import Path
import subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parent
class SnapshotTests(unittest.TestCase):
    def test_scp_snapshot_owns_its_firmware_sized_copy_after_device_removal(self):
        source = (ROOT / 'n1x_scp.c').read_text()
        functions = source[source.index('struct n1x_scp_snapshot {'):
                           source.index('static const struct file_operations n1x_scp_snapshot_fops')]
        code = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
typedef uint8_t u8;
#define __user
#define GFP_KERNEL 0
#define struct_size(p,m,n) (sizeof(*(p))+(n))
struct inode {void *i_private;};struct file {void *private_data;};
struct n1x_scp {void *sram;size_t size;};
static bool fail;static size_t copied;
static void *kvmalloc(size_t bytes,int flags) {assert(flags==GFP_KERNEL);return fail?NULL:malloc(bytes);}
#define kvfree(p) free(p)
static void memcpy_fromio(void *to,const void *from,size_t bytes) {copied=bytes;memcpy(to,from,bytes);}
static ssize_t simple_read_from_buffer(char *to,size_t count,loff_t *pos,const void *from,size_t bytes)
{if((size_t)*pos>=bytes)return 0;size_t n=bytes-*pos;if(n>count)n=count;memcpy(to,(const u8 *)from+*pos,n);*pos+=n;return n;}
''' + functions + r'''
int main(void)
{
 for(unsigned size=4096;size<=1048576;size*=4){
  struct n1x_scp scp={malloc(size),size};assert(scp.sram);memset(scp.sram,0x5a,size);
  struct inode inode={&scp};struct file file={0};fail=true;
  assert(n1x_scp_snapshot_open(&inode,&file)==-ENOMEM && !file.private_data);fail=false;
  assert(!n1x_scp_snapshot_open(&inode,&file) && copied==size);
  memset(scp.sram,0xa5,size);free(scp.sram);scp.sram=NULL;scp.size=0;
  char bytes[777];loff_t pos=0;size_t total=0;ssize_t n;
  while((n=n1x_scp_snapshot_read(&file,bytes,sizeof(bytes),&pos))>0){
   for(ssize_t i=0;i<n;i++)assert(bytes[i]==0x5a);total+=n;
  }
  assert(!n && total==size && !n1x_scp_snapshot_release(&inode,&file));
 }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            source, binary = Path(temporary) / 'snapshot.c', Path(temporary) / 'snapshot'
            source.write_text(code)
            subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            '-Wno-unused-parameter', '-Wno-misleading-indentation',
                            '-fsanitize=address,undefined', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

if __name__=="__main__": unittest.main()
