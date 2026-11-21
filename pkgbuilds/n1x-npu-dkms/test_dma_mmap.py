#!/usr/bin/python
"""Extract the provider mmap and exact kernel IOMMU/remap functions; no hardware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def function(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path, nargs="?")
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--provider", type=Path, default=Path(os.environ.get("N1X_SOURCE_ROOT", ROOT / "src/n1x-npu")) / "driver/n1x_dla_accel.c")
    args = parser.parse_args()
    if args.fixture:
        fixture = json.loads(args.fixture.read_text())
        sources = fixture["sources"]
        hashes = fixture["source_sha256"]
    else:
        paths = {name: args.kernel / name for name in ("drivers/iommu/dma-iommu.c", "kernel/dma/remap.c", "mm/memory.c")}
        sources = {name: path.read_text() for name, path in paths.items()}
        hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    bodies = function(sources["kernel/dma/remap.c"], "struct page **dma_common_find_pages(")
    bodies += function(sources["mm/memory.c"], "static int __vm_map_pages(")
    bodies += function(sources["mm/memory.c"], "int vm_map_pages(")
    bodies += function(sources["drivers/iommu/dma-iommu.c"], "int iommu_dma_mmap(")
    bodies += "\n#define dma_mmap_coherent(d,v,c,a,s) iommu_dma_mmap(d,v,c,a,s,0)\n"
    bodies += function(args.provider.read_text(), "static int n1x_accel_mmap(")
    shim = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint64_t u64;
typedef uint64_t dma_addr_t;
#define PAGE_SHIFT 12
#define PAGE_SIZE (1UL << PAGE_SHIFT)
#define PAGE_ALIGN(x) (((x)+PAGE_SIZE-1)&~(PAGE_SIZE-1))
#define N1X_JOB_PREFIX 8192U
#define VM_WRITE 2
#define VM_MAYWRITE 32
#define VM_DMA_COHERENT 4
#define WARN(c,...) assert(!(c))
struct page {unsigned char *data;};
struct vm_struct {unsigned flags;struct page **pages;};
struct device {int unused;};
struct drm_device {struct device *dev;};
struct drm_minor {struct drm_device *dev;};
struct drm_file {struct drm_minor *minor;};
struct file {void *private_data;};
struct vm_area_struct {unsigned long vm_start,vm_end,vm_flags,vm_pgoff,vm_page_prot;void *vm_private_data;const void *vm_ops;};
struct n1x_dla_accel {struct drm_device drm;int lock,jobs;bool unplugged,stopped;};
struct n1x_accel_job {u64 id;struct drm_file *owner;struct {int error;bool verified,suspended;unsigned char *buffer;dma_addr_t dma;} task;size_t allocated;unsigned image_bytes,mmap_count;struct n1x_dla_accel *accel;};
static struct n1x_accel_job fixture;
static struct n1x_dla_accel accel;
static int n1x_accel_vm_ops;
static unsigned char allocation[6*PAGE_SIZE];
static struct page page_store[6];
static struct page *page_list[6];
static struct vm_struct area={VM_DMA_COHERENT,page_list};
static unsigned char mapped[6*PAGE_SIZE];
static unsigned inserted;
static struct vm_struct *find_vm_area(void *cpu)
{return (uintptr_t)cpu >= (uintptr_t)allocation && (uintptr_t)cpu < (uintptr_t)allocation+sizeof(allocation) ? &area : NULL;}
static unsigned long vma_pages(struct vm_area_struct *v) {return (v->vm_end-v->vm_start)>>PAGE_SHIFT;}
static unsigned long vma_start_pgoff(struct vm_area_struct *v) {return v->vm_pgoff;}
static int vm_insert_pages(struct vm_area_struct *v,unsigned long addr,struct page **pages,unsigned long *count)
{assert(addr==v->vm_start);assert(*count<=6);for(unsigned i=0;i<*count;i++)memcpy(mapped+i*PAGE_SIZE,pages[i]->data,PAGE_SIZE);inserted=*count;return 0;}
static unsigned long dma_pgprot(struct device *d,unsigned long prot,unsigned long attrs) {(void)d;(void)attrs;return prot;}
static int dma_mmap_from_dev_coherent(struct device *d,struct vm_area_struct *v,void *cpu,size_t size,int *ret)
{(void)d;(void)v;(void)cpu;(void)size;(void)ret;return 0;}
static bool is_vmalloc_addr(void *cpu) {return find_vm_area(cpu)!=NULL;}
static unsigned long vmalloc_to_pfn(void *cpu) {(void)cpu;abort();}
static struct page *virt_to_page(void *cpu) {(void)cpu;abort();}
static unsigned long page_to_pfn(struct page *page) {(void)page;abort();}
static int remap_pfn_range(struct vm_area_struct *v,unsigned long start,unsigned long pfn,unsigned long size,unsigned long prot)
{(void)v;(void)start;(void)pfn;(void)size;(void)prot;abort();}
static struct n1x_dla_accel *to_accel(struct drm_device *d) {assert(d==&accel.drm);return &accel;}
static bool n1x_accel_permitted(void) {return true;}
static void mutex_lock(int *lock) {assert(!*lock);*lock=1;}
static void mutex_unlock(int *lock) {assert(*lock);*lock=0;}
static void vm_flags_clear(struct vm_area_struct *v,unsigned long flags) {v->vm_flags&=~flags;}
#define list_for_each_entry(pos,head,member) for((pos)=&fixture;(pos);(pos)=NULL)
'''
    test = r'''
int main(void) {
 struct device dev;struct drm_minor minor={&accel.drm};struct drm_file owner={&minor},other={&minor};struct file filp={&owner};
 accel.drm.dev=&dev;
 for(unsigned i=0;i<6;i++){page_store[i].data=allocation+i*PAGE_SIZE;page_list[i]=&page_store[i];memset(page_store[i].data,0x30+i,PAGE_SIZE);}
 fixture=(struct n1x_accel_job){.id=77,.owner=&owner,.task={.verified=true,.buffer=allocation,.dma=0x100000000ULL},.allocated=5*PAGE_SIZE,.image_bytes=2*PAGE_SIZE+13};
 struct vm_area_struct vma={.vm_start=0x1000,.vm_end=0x2000,.vm_flags=VM_MAYWRITE,.vm_pgoff=77};
 assert(!n1x_accel_mmap(&filp,&vma));
 if(inserted!=1 || mapped[0]!=0x32 || mapped[PAGE_SIZE-1]!=0x32){fprintf(stderr,"wrong page: mapped prefix=%#x instead of image=%#x\n",mapped[0],0x32);return 2;}
 assert(!(vma.vm_flags&VM_MAYWRITE)&&fixture.mmap_count==1&&vma.vm_private_data==&fixture);
 vma.vm_end=0x4000;vma.vm_pgoff=77;assert(!n1x_accel_mmap(&filp,&vma));assert(inserted==3&&mapped[2*PAGE_SIZE]==0x34);
 vma.vm_end=0x5000;vma.vm_pgoff=77;inserted=0;assert(n1x_accel_mmap(&filp,&vma)==-EINVAL&&!inserted);
 vma.vm_end=0x2000;vma.vm_flags=VM_WRITE;assert(n1x_accel_mmap(&filp,&vma)==-EINVAL);vma.vm_flags=VM_MAYWRITE;
 filp.private_data=&other;assert(n1x_accel_mmap(&filp,&vma)==-ENOENT);filp.private_data=&owner;
 fixture.task.verified=false;assert(n1x_accel_mmap(&filp,&vma)==-EIO);fixture.task.verified=true;
 fixture.task.suspended=true;assert(n1x_accel_mmap(&filp,&vma)==-EIO);fixture.task.suspended=false;
 accel.stopped=true;assert(n1x_accel_mmap(&filp,&vma)==-ENODEV);
 puts("Exact IOMMU/remap C: image-page mapping, partial/full image, bounds, read-only, ownership and stopped/suspended cases passed; no hardware");
}
'''
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)
        (path / "test.c").write_text(shim + bodies + test)
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-fsanitize=undefined", str(path / "test.c"), "-o", str(path / "test")], check=True)
        run = subprocess.run([str(path / "test")], capture_output=True, text=True)
        print(run.stdout, end="")
        print(run.stderr, end="")
        print(json.dumps({"kernel": str(args.kernel), "provider": str(args.provider), "source_sha256": hashes, "exit_code": run.returncode}))
        raise SystemExit(run.returncode)


if __name__ == "__main__":
    main()
