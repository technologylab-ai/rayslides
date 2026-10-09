// Preserve the binding-only workaround used by the Zig 0.16 @cImport.
// MPack's GCC _Pragma warning wrapper is not a declaration. Preload its
// standard headers before hiding those macros so libc type selection stays
// unchanged. The separately compiled C implementation keeps normal macros.
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <inttypes.h>
#include <limits.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <stdarg.h>
#undef __GNUC__
#undef __GNUC_MINOR__
#define MPACK_EXTENSIONS 1
#include <mpack.h>
