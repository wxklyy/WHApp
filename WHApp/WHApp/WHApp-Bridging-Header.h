#ifndef BridgingHeader_h
#define BridgingHeader_h

#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <unistd.h>

// inject dylib into pid — returns NULL on success, error string on failure
const char* inject_dylib(pid_t pid, const char* dylib_path);

// find pid by process name
pid_t find_pid(const char* name);

#endif
