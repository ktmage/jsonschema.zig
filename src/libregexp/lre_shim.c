#include <stdlib.h>
#include <stddef.h>

/* Required callbacks for libregexp */
void *lre_realloc(void *opaque, void *ptr, size_t size) {
    (void)opaque;
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, size);
}

int lre_check_stack_overflow(void *opaque, size_t alloca_size) {
    (void)opaque;
    (void)alloca_size;
    return 0; /* no overflow */
}

int lre_check_timeout(void *opaque) {
    (void)opaque;
    return 0; /* no timeout */
}
