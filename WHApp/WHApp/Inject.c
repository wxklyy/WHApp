#include "WHApp-Bridging-Header.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <spawn.h>

// ── mach_vm_* are private on iOS — declare manually ──
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
typedef uint64_t mach_vm_offset_t;

extern kern_return_t mach_vm_allocate(
    vm_map_t target,
    mach_vm_address_t *address,
    mach_vm_size_t size,
    int flags
);

extern kern_return_t mach_vm_write(
    vm_map_t target_task,
    mach_vm_address_t address,
    vm_offset_t data,
    mach_msg_type_number_t dataCnt
);

extern kern_return_t mach_vm_protect(
    vm_map_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    boolean_t set_maximum,
    vm_prot_t new_protection
);

extern kern_return_t mach_vm_deallocate(
    vm_map_t target,
    mach_vm_address_t address,
    mach_vm_size_t size
);

// ARM_THREAD_STATE64_COUNT macro is unavailable in Swift/iOS SDK — hardcode
#define MY_ARM_THREAD_STATE64_COUNT 68

const char* inject_dylib(pid_t pid, const char* dylib_path) {
    static char errbuf[512];

    // get task port — requires task_for_pid-allow (TrollStore grants this)
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "task_for_pid failed: %d (need TrollStore entitlements)", kr);
        return errbuf;
    }

    size_t path_len = strlen(dylib_path) + 1;

    // allocate memory in target process for dylib path
    mach_vm_address_t remote_addr = 0;
    kr = mach_vm_allocate(task, &remote_addr, (mach_vm_size_t)path_len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "mach_vm_allocate failed: %d", kr);
        mach_port_deallocate(mach_task_self(), task);
        return errbuf;
    }

    // write dylib path string into target process
    kr = mach_vm_write(task, remote_addr, (vm_offset_t)dylib_path, (mach_msg_type_number_t)path_len);
    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "mach_vm_write failed: %d", kr);
        mach_vm_deallocate(task, remote_addr, path_len);
        mach_port_deallocate(mach_task_self(), task);
        return errbuf;
    }

    mach_vm_protect(task, remote_addr, (mach_vm_size_t)path_len, 0, VM_PROT_READ | VM_PROT_WRITE);

    // dlopen address — same in both processes via shared dyld cache
    void* dlopen_addr = dlsym(RTLD_DEFAULT, "dlopen");
    if (!dlopen_addr) {
        snprintf(errbuf, sizeof(errbuf), "dlsym(dlopen) failed");
        return errbuf;
    }

    // set up arm64 thread state to call dlopen(path, RTLD_NOW)
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__x[0] = (uint64_t)remote_addr; // arg0: path
    state.__x[1] = (uint64_t)RTLD_NOW;    // arg1: mode
    state.__pc   = (uint64_t)(uintptr_t)dlopen_addr;
    state.__sp   = remote_addr + 0x4000;  // scratch stack above path

    // spawn remote thread at dlopen — this loads our dylib
    thread_act_t remote_thread = 0;
    kr = thread_create_running(
        task,
        ARM_THREAD_STATE64,
        (thread_state_t)&state,
        MY_ARM_THREAD_STATE64_COUNT,
        &remote_thread
    );

    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "thread_create_running failed: %d", kr);
        mach_vm_deallocate(task, remote_addr, path_len);
        mach_port_deallocate(mach_task_self(), task);
        return errbuf;
    }

    // wait for dlopen to finish in remote process
    usleep(800000); // 800ms

    // cleanup
    thread_terminate(remote_thread);
    mach_port_deallocate(mach_task_self(), remote_thread);
    mach_vm_deallocate(task, remote_addr, path_len);
    mach_port_deallocate(mach_task_self(), task);

    return NULL; // success
}

pid_t find_pid(const char* name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;

    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return 0;

    int count = (int)(size / sizeof(struct kinfo_proc));
    struct kinfo_proc* procs = (struct kinfo_proc*)malloc(size);
    if (!procs) return 0;

    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return 0;
    }

    pid_t result = 0;
    for (int i = 0; i < count; i++) {
        if (strncasecmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            result = procs[i].kp_proc.p_pid;
            break;
        }
    }

    free(procs);
    return result;
}

void do_respring(void) {
    pid_t pid;
    const char* args[] = { "/var/jb/usr/bin/sbreload", NULL };
    posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char* const*)args, NULL);
}
