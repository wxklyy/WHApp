#ifndef BridgingHeader_h
#define BridgingHeader_h

#include <sys/types.h>
#include <unistd.h>

// Inject LC_LOAD_DYLIB directly into Mach-O binary (returns 1 on success, 0 if already hooked, negative on error)
int patch_macho_add_dylib(const char* binary_path, const char* dylib_load_path);

// Resign binary using ldid if available
int resign_binary(const char* binary_path);

// Find running process PID by name
pid_t find_pid(const char* name);

// Respring SpringBoard
void do_respring(void);

#endif
