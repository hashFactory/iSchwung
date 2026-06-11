/* macOS has no <malloc.h>; upstream chain_host.c includes it. malloc/free
 * live in <stdlib.h> here. Added via -I so the repo stays unmodified. */
#include <stdlib.h>

/* glibc extension; macOS reclaims via its allocator on its own. */
static inline int malloc_trim(size_t pad) { (void)pad; return 0; }
