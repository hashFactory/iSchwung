/* apple_compat_overrides.h - Force-included (-include) when compiling unmodified
 * schwung sources and quickjs-libc for macOS.
 *
 * Remaps filesystem calls so the hardcoded "/data/UserData" tree resolves into a
 * per-user data root, without touching upstream sources. System headers are
 * included FIRST so the function-like macros below never rewrite their
 * declarations (asm-label aliases on Darwin would silently bypass the wrappers).
 */

#ifndef APPLE_COMPAT_OVERRIDES_H
#define APPLE_COMPAT_OVERRIDES_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <dirent.h>
#include <limits.h>
#include <time.h>
#include <sched.h>
#include <utime.h>
#include <sys/time.h>
#include <dlfcn.h>
#include <TargetConditionals.h>

#ifdef __cplusplus
extern "C" {
#endif

FILE *schwung_compat_fopen(const char *path, const char *mode);
int schwung_compat_open(const char *path, int flags, ...);
int schwung_compat_stat(const char *path, struct stat *st);
int schwung_compat_lstat(const char *path, struct stat *st);
int schwung_compat_access(const char *path, int mode);
DIR *schwung_compat_opendir(const char *path);
int schwung_compat_mkdir(const char *path, mode_t mode);
int schwung_compat_rmdir(const char *path);
int schwung_compat_remove(const char *path);
int schwung_compat_unlink(const char *path);
int schwung_compat_rename(const char *from, const char *to);
char *schwung_compat_realpath(const char *path, char *resolved);
int schwung_compat_execvp(const char *file, char *const argv[]);
int schwung_compat_utimes(const char *path, const struct timeval *times);
ssize_t schwung_compat_readlink(const char *path, char *buf, size_t bufsiz);
int schwung_compat_symlink(const char *target, const char *linkpath);
int schwung_compat_truncate(const char *path, off_t length);
void *schwung_compat_dlopen(const char *path, int mode);
int schwung_compat_shm_open(const char *name, int oflag, int mode);
int schwung_compat_shm_unlink(const char *name);
int schwung_compat_fork_unavailable(void);
int schwung_compat_system_unavailable(const char *cmd);

#ifdef __cplusplus
}
#endif

#define fopen(p, m)        schwung_compat_fopen((p), (m))
#define open(...)          schwung_compat_open(__VA_ARGS__)
#define stat(p, st)        schwung_compat_stat((p), (st))
#define lstat(p, st)       schwung_compat_lstat((p), (st))
#define access(p, m)       schwung_compat_access((p), (m))
#define opendir(p)         schwung_compat_opendir(p)
#define mkdir(p, m)        schwung_compat_mkdir((p), (m))
#define rmdir(p)           schwung_compat_rmdir(p)
#define remove(p)          schwung_compat_remove(p)
#define unlink(p)          schwung_compat_unlink(p)
#define rename(a, b)       schwung_compat_rename((a), (b))
#define realpath(p, r)     schwung_compat_realpath((p), (r))
#define execvp(f, a)       schwung_compat_execvp((f), (a))
#define utimes(p, t)       schwung_compat_utimes((p), (t))
#define readlink(p, b, s)  schwung_compat_readlink((p), (b), (s))
#define symlink(t, l)      schwung_compat_symlink((t), (l))
#define truncate(p, l)     schwung_compat_truncate((p), (l))
#define dlopen(p, m)       schwung_compat_dlopen((p), (m))
/* Real POSIX shm on macOS; file-backed mmap regions inside the sandbox on iOS. */
#define shm_open(n, f, ...) schwung_compat_shm_open((n), (f), 0666)
#define shm_unlink(n)       schwung_compat_shm_unlink(n)

#if TARGET_OS_IPHONE
/* No subprocesses on iOS: make fork() fail cleanly so upstream helpers
 * (curl/tar/mkdir spawns) take their error paths instead of crashing. */
#define fork() schwung_compat_fork_unavailable()
#define system(cmd) schwung_compat_system_unavailable(cmd)
#endif

/* macOS has no sched_setscheduler; schwung only uses it to DROP RT priority
 * before fork/exec, which is a no-op concern here. */
#define sched_setscheduler(pid, policy, param) (0)

#endif /* APPLE_COMPAT_OVERRIDES_H */
