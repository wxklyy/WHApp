#include "WHApp-Bridging-Header.h"
#include <stdio.h>
#include <string.h>

// ARM_THREAD_STATE64_COUNT as raw value (unavailable as macro in Swift)
#define MY_ARM_THREAD_STATE64_COUNT 68

const char* inject_dylib(pid_t pid, const char* dylib_path) {
    static char errbuf[256];

    // get task port for target process
    // requires task_for_pid-allow entitlement (granted by TrollStore)
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "task_for_pid failed: %d", kr);
        return errbuf;
    }

    size_t path_len = strlen(dylib_path) + 1;

    // allocate memory in target process
    mach_vm_address_t remote_addr = 0;
    kr = mach_vm_allocate(task, &remote_addr, (mach_vm_size_t)path_len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "mach_vm_allocate failed: %d", kr);
        mach_port_deallocate(mach_task_self(), task);
        return errbuf;
    }

    // write dylib path into target process
    kr = mach_vm_write(task, remote_addr, (vm_offset_t)dylib_path, (mach_msg_type_number_t)path_len);
    if (kr != KERN_SUCCESS) {
        snprintf(errbuf, sizeof(errbuf), "mach_vm_write failed: %d", kr);
        mach_vm_deallocate(task, remote_addr, path_len);
        mach_port_deallocate(mach_task_self(), task);
        return errbuf;
    }

    // set memory to readable
    mach_vm_protect(task, remote_addr, (mach_vm_size_t)path_len, 0, VM_PROT_READ | VM_PROT_WRITE);

    // get dlopen address from our process
    // since both processes use the same dyld shared cache, address is valid in target too
    void* dlopen_addr = dlsym(RTLD_DEFAULT, "dlopen");
    if (!dlopen_addr) {
        snprintf(errbuf, sizeof(errbuf), "dlsym(dlopen) failed");
        return errbuf;
    }

    // set up arm64 thread state
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));

    // x0 = path, x1 = RTLD_NOW (2)
    state.__x[0] = (uint64_t)remote_addr;
    state.__x[1] = (uint64_t)RTLD_NOW;
    state.__pc    = (uint64_t)(uintptr_t)dlopen_addr;
    state.__sp    = remote_addr + 0x1000; // scratch stack

    // create thread in target at dlopen
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

    // wait for dlopen to finish
    usleep(600000); // 600ms

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
