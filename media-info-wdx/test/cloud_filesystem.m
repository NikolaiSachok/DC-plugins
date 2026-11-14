/* Test-only availability shim; loaded before the built WDX plugin. */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/mount.h>
const char *probePath;
BOOL offline, statError, sawPolicy, nonlocal;
static int ProbeStat(const char *path, struct stat *st) {
    if (probePath && strcmp(path,probePath)==0) {
        sawPolicy=getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD)==IOPOL_MATERIALIZE_DATALESS_FILES_OFF;
        if (statError) { errno=EDEADLK; return -1; }
        int result=stat(path,st);
        if (result==0 && offline) st->st_flags|=SF_DATALESS;
        return result;
    }
    return stat(path,st);
}
__attribute__((used)) static const struct { const void *replacement, *original; } interposeStat
    __attribute__((section("__DATA,__interpose"))) = {(const void *)ProbeStat,(const void *)stat};

static int ProbeStatFS(const char *path, struct statfs *st) {
    int result=statfs(path,st);
    if (result==0 && probePath && strcmp(path,probePath)==0 && nonlocal) st->f_flags&=~MNT_LOCAL;
    return result;
}
__attribute__((used)) static const struct { const void *replacement, *original; } interposeStatFS
    __attribute__((section("__DATA,__interpose"))) = {(const void *)ProbeStatFS,(const void *)statfs};
