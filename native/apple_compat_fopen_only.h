/* apple_compat_fopen_only.h - A narrow alternative to apple_compat_overrides.h
 * for C++ modules that pull in the STL. The full overrides #define function-like
 * macros named remove/open/etc., which collide with std::remove and friends in
 * <algorithm> ("too many arguments provided to function-like macro invocation").
 *
 * Most ported synths only touch the filesystem through fopen (to load presets
 * from their module dir). fopen always takes two args, so remapping it alone is
 * STL-safe, while still routing /data/UserData paths into the per-user data root.
 */
#ifndef APPLE_COMPAT_FOPEN_ONLY_H
#define APPLE_COMPAT_FOPEN_ONLY_H

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif
FILE *schwung_compat_fopen(const char *path, const char *mode);
#ifdef __cplusplus
}
#endif

#define fopen(p, m) schwung_compat_fopen((p), (m))

#endif /* APPLE_COMPAT_FOPEN_ONLY_H */
