#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#define PAGE_SHIFT 12
#define PAGE_SIZE (1UL << PAGE_SHIFT)
#define MAX_RW_COUNT (INT_MAX & ~(PAGE_SIZE - 1))

static int page_array_size(uintptr_t start, uint64_t len,
                           size_t *npages, size_t *bytes)
{
    uintptr_t last;

    if (!len || len > MAX_RW_COUNT)
        return -EINVAL;
    if (__builtin_add_overflow(start, len - 1, &last))
        return -EOVERFLOW;

    *npages = (((last & ~(PAGE_SIZE - 1)) -
                (start & ~(PAGE_SIZE - 1))) >> PAGE_SHIFT) + 1;
    if (!*npages || *npages > INT_MAX)
        return -E2BIG;
    if (__builtin_mul_overflow(*npages, sizeof(void *), bytes))
        return -EOVERFLOW;

    return 0;
}

int main(void)
{
    const uintptr_t start = UINT64_C(0x100000000);
    const uint64_t exploit_pages = UINT64_C(0x20000001);
    const uint64_t ordinary_size = UINT64_C(64) * 1024 * 1024;
    size_t npages;
    size_t bytes;

    assert(page_array_size(start, ordinary_size, &npages, &bytes) == 0);
    assert(npages == ordinary_size / PAGE_SIZE);
    assert(bytes == (ordinary_size / PAGE_SIZE) * sizeof(void *));

    assert(page_array_size(start, exploit_pages * PAGE_SIZE,
                           &npages, &bytes) == -EINVAL);
    assert(page_array_size(UINTPTR_MAX - 100, 200,
                           &npages, &bytes) == -EOVERFLOW);
    assert(page_array_size(start, 0, &npages, &bytes) == -EINVAL);

    return 0;
}
