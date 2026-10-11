#include "WHApp-Bridging-Header.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <mach-o/loader.h>

int patch_macho_add_dylib(const char* binary_path, const char* dylib_load_path) {
    FILE* f = fopen(binary_path, "r+b");
    if (!f) return -1;

    struct mach_header_64 header;
    if (fread(&header, sizeof(header), 1, f) != 1) {
        fclose(f);
        return -2;
    }

    if (header.magic != MH_MAGIC_64) {
        fclose(f);
        return -3; // Not 64-bit Mach-O
    }

    uint64_t min_section_offset = 0;
    bool found_existing = false;

    // Check existing load commands
    fseek(f, sizeof(struct mach_header_64), SEEK_SET);
    for (uint32_t i = 0; i < header.ncmds; i++) {
        long cmd_pos = ftell(f);
        struct load_command lc;
        if (fread(&lc, sizeof(lc), 1, f) != 1) break;

        if (lc.cmd == LC_LOAD_DYLIB || lc.cmd == LC_LOAD_WEAK_DYLIB) {
            fseek(f, cmd_pos, SEEK_SET);
            struct dylib_command dc;
            if (fread(&dc, sizeof(dc), 1, f) == 1) {
                char name_buf[512] = {0};
                fseek(f, cmd_pos + dc.dylib.name.offset, SEEK_SET);
                fread(name_buf, 1, sizeof(name_buf) - 1, f);
                if (strstr(name_buf, "StandoffWH.dylib")) {
                    found_existing = true;
                }
            }
        }

        if (lc.cmd == LC_SEGMENT_64) {
            fseek(f, cmd_pos, SEEK_SET);
            struct segment_command_64 seg;
            if (fread(&seg, sizeof(seg), 1, f) == 1) {
                for (uint32_t s = 0; s < seg.nsects; s++) {
                    struct section_64 sect;
                    if (fread(&sect, sizeof(sect), 1, f) == 1) {
                        if (sect.offset > 0 && (min_section_offset == 0 || sect.offset < min_section_offset)) {
                            min_section_offset = sect.offset;
                        }
                    }
                }
            }
        }

        fseek(f, cmd_pos + lc.cmdsize, SEEK_SET);
    }

    if (found_existing) {
        fclose(f);
        return 0; // Already injected
    }

    // 8-byte aligned size
    size_t str_len = strlen(dylib_load_path) + 1;
    uint32_t cmdsize = (uint32_t)(sizeof(struct dylib_command) + str_len);
    cmdsize = (cmdsize + 7) & ~7;

    long end_of_cmds = sizeof(struct mach_header_64) + header.sizeofcmds;

    if (min_section_offset > 0 && (end_of_cmds + cmdsize > min_section_offset)) {
        fclose(f);
        return -4; // Not enough header padding
    }

    struct dylib_command dc;
    memset(&dc, 0, sizeof(dc));
    dc.cmd = LC_LOAD_DYLIB;
    dc.cmdsize = cmdsize;
    dc.dylib.name.offset = sizeof(struct dylib_command);
    dc.dylib.timestamp = 2;
    dc.dylib.current_version = 0x00010000;
    dc.dylib.compatibility_version = 0x00010000;

    fseek(f, end_of_cmds, SEEK_SET);
    fwrite(&dc, sizeof(dc), 1, f);
    fwrite(dylib_load_path, str_len, 1, f);
    size_t pad = cmdsize - (sizeof(struct dylib_command) + str_len);
    if (pad > 0) {
        char pad_zeros[8] = {0};
        fwrite(pad_zeros, 1, pad, f);
    }

    header.ncmds += 1;
    header.sizeofcmds += cmdsize;
    fseek(f, 0, SEEK_SET);
    fwrite(&header, sizeof(header), 1, f);

    fclose(f);
    return 1; // Injected!
}

int resign_binary(const char* binary_path) {
    const char* ldid_candidates[] = {
        "/var/jb/usr/bin/ldid",
        "/usr/bin/ldid",
        "/var/jb/bin/ldid",
        "/usr/local/bin/ldid",
        NULL
    };

    for (int i = 0; ldid_candidates[i]; i++) {
        if (access(ldid_candidates[i], X_OK) == 0) {
            pid_t pid;
            const char* args[] = { ldid_candidates[i], "-s", binary_path, NULL };
            int status = 0;
            if (posix_spawn(&pid, ldid_candidates[i], NULL, NULL, (char* const*)args, NULL) == 0) {
                waitpid(pid, &status, 0);
                return WEXITSTATUS(status);
            }
        }
    }
    return 0;
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
