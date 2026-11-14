"""C fixture declarations and fault cases for the NVIDIA DRM transaction."""
PRELUDE = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>
typedef unsigned NvU32;
#define DRM_MODESET_ACQUIRE_INTERRUPTIBLE 1
#define NV_DRM_INPUT_COLOR_SPACE_NONE 0
#define IS_ERR(p) ((intptr_t)(p)<0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
struct drm_device {int dummy;};
struct drm_modeset_acquire_ctx {int contended;};
typedef struct {struct drm_modeset_acquire_ctx *acquire_ctx;} nv_drm_atomic_state_base_t;
struct drm_plane {int index;};
struct drm_plane_state {int index;};
struct nv_drm_plane_state {int input_colorspace;};
static struct drm_plane planes[2]={{0},{1}};
static struct drm_plane_state ps[2]={{0},{1}};
static struct nv_drm_plane_state colors[2];
static nv_drm_atomic_state_base_t state;
static int scenario,gets,commits,clears,backoffs,puts,drops,finis,warnings;
#define nv_drm_for_each_plane(p,d) for(int i=0;(void)(d),i<2 && ((p)=&planes[i],1);i++)
static nv_drm_atomic_state_base_t *nv_drm_atomic_state_base_alloc(struct drm_device *d)
{(void)d;return scenario==6?NULL:&state;}
static void drm_modeset_acquire_init(struct drm_modeset_acquire_ctx *c,NvU32 flags)
{assert(flags==1);c->contended=0;}
static struct drm_plane_state *drm_atomic_get_plane_state(nv_drm_atomic_state_base_t *s,struct drm_plane *p)
{
 gets++;
 if(!backoffs && ((scenario==1 && p->index==0) || (scenario==3 && p->index==0) || (scenario==5 && p->index==1))) {
  s->acquire_ctx->contended=1;return (void *)(intptr_t)-EDEADLK;
 }
 if(scenario==4)return (void *)(intptr_t)-EINVAL;
 return &ps[p->index];
}
static struct nv_drm_plane_state *to_nv_drm_plane_state(struct drm_plane_state *p)
{return &colors[p->index];}
static int drm_atomic_commit(nv_drm_atomic_state_base_t *s)
{
 commits++;if(scenario==2 && !backoffs){s->acquire_ctx->contended=1;return -EDEADLK;}
 return 0;
}
static void nv_drm_atomic_state_clear(nv_drm_atomic_state_base_t *s)
{
 assert(s==&state);clears++;
 /* Current state may change while locks are dropped: rebuild, never reuse. */
 colors[0].input_colorspace=scenario==5?0:1;colors[1].input_colorspace=0;
}
static int drm_modeset_backoff(struct drm_modeset_acquire_ctx *c)
{assert(c->contended && clears==backoffs+1);c->contended=0;backoffs++;return scenario==3?-512:0;}
static void nv_drm_atomic_state_base_put(nv_drm_atomic_state_base_t *s)
{assert(s==&state);puts++;}
static void drm_modeset_drop_locks(struct drm_modeset_acquire_ctx *c)
{drops++;warnings+=!!c->contended;}
static void drm_modeset_acquire_fini(struct drm_modeset_acquire_ctx *c)
{(void)c;finis++;}
'''
MAIN = r'''
int main(int argc,char **argv) {
 assert(argc==2);bool fixed=atoi(argv[1]);struct drm_device dev={0};
 for(scenario=0;scenario<8;scenario++) {
  gets=commits=clears=backoffs=puts=drops=finis=warnings=0;
  colors[0].input_colorspace=scenario==7?0:1;colors[1].input_colorspace=0;
  int rc=nv_drm_reset_input_colorspace(&dev);
  bool deadlock=scenario==1 || scenario==2 || scenario==3 || scenario==5;
  if(!fixed && deadlock){assert(rc==-EDEADLK && warnings==1 && !backoffs);continue;}
  assert(!warnings);
  assert(rc==(scenario==3?-512:scenario==4?-EINVAL:scenario==6?-ENOMEM:0));
  assert(puts==(scenario==6?0:1) && drops==puts && finis==puts);
  assert(backoffs==(deadlock?1:0) && clears==backoffs);
  if(scenario==5 || scenario==7)assert(!commits);
  if(scenario==2)assert(commits==2);
 }
 return 0;
}
'''
