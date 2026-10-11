import SwiftUI
import Darwin

// ══════════════════════════════════════
// Mach inject core
// ══════════════════════════════════════

// private entitlements granted by TrollStore:
// task_for_pid-allow, platform-application, get-task-allow

typealias MachPort = mach_port_t

func injectDylib(pid: pid_t, dylibPath: String) -> String {
    var task: MachPort = 0

    // get task port — works because TrollStore grants task_for_pid-allow
    let kr = task_for_pid(mach_task_self_, pid, &task)
    guard kr == KERN_SUCCESS else {
        return "task_for_pid failed: \(kr) — make sure TrollStore granted entitlements"
    }

    // allocate memory in target process for the dylib path string
    let pathBytes = Array(dylibPath.utf8) + [0]
    let pathSize = pathBytes.count

    var remoteAddr: mach_vm_address_t = 0
    var kr2 = mach_vm_allocate(task, &remoteAddr, mach_vm_size_t(pathSize), Int32(VM_FLAGS_ANYWHERE))
    guard kr2 == KERN_SUCCESS else {
        return "mach_vm_allocate failed: \(kr2)"
    }

    // write dylib path into target process memory
    var kr3 = pathBytes.withUnsafeBytes { ptr in
        mach_vm_write(task, remoteAddr, vm_offset_t(bitPattern: ptr.baseAddress), mach_msg_type_number_t(pathSize))
    }
    guard kr3 == KERN_SUCCESS else {
        return "mach_vm_write failed: \(kr3)"
    }

    // set memory protection to rx
    _ = mach_vm_protect(task, remoteAddr, mach_vm_size_t(pathSize), 0, VM_PROT_READ | VM_PROT_WRITE)

    // get dlopen address from our process (same dyld in target)
    guard let dlopenAddr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dlopen") else {
        return "dlsym(dlopen) failed"
    }

    // create remote thread at dlopen with our path as argument
    // arm64 thread state
    var state = arm_thread_state64_t()
    var stateCount = mach_msg_type_number_t(ARM_THREAD_STATE64_COUNT)

    // set PC = dlopen, x0 = remoteAddr (path), x1 = RTLD_NOW
    withUnsafeMutableBytes(of: &state.__x) { ptr in
        // x0 = path pointer
        ptr.storeBytes(of: remoteAddr, toByteOffset: 0, as: UInt64.self)
        // x1 = RTLD_NOW (2)
        ptr.storeBytes(of: UInt64(RTLD_NOW), toByteOffset: 8, as: UInt64.self)
    }
    state.__pc = UInt64(UInt(bitPattern: dlopenAddr))
    // set sp to some stack area
    state.__sp = remoteAddr + mach_vm_address_t(0x1000)

    var remoteThread: thread_act_t = 0
    let kr4 = withUnsafeMutablePointer(to: &state) { statePtr in
        statePtr.withMemoryRebound(to: UInt32.self, capacity: Int(ARM_THREAD_STATE64_COUNT)) { rawState in
            thread_create_running(task, ARM_THREAD_STATE64, rawState, ARM_THREAD_STATE64_COUNT, &remoteThread)
        }
    }

    guard kr4 == KERN_SUCCESS else {
        return "thread_create_running failed: \(kr4)"
    }

    // wait a bit for dlopen to complete
    Thread.sleep(forTimeInterval: 0.5)
    thread_terminate(remoteThread)
    mach_port_deallocate(mach_task_self_, task)

    return "OK"
}

// ══════════════════════════════════════
// PID finder
// ══════════════════════════════════════

func findPID(name: String) -> pid_t {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    sysctl(&mib, 4, nil, &size, nil, 0)

    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    sysctl(&mib, 4, &procs, &size, nil, 0)

    for var p in procs {
        let n = withUnsafeBytes(of: &p.kp_proc.p_comm) {
            String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        }
        if n.lowercased().contains(name.lowercased()) {
            return p.kp_proc.p_pid
        }
    }
    return 0
}

// ══════════════════════════════════════
// UI
// ══════════════════════════════════════

struct ContentView: View {
    @State private var log: [LogLine] = []
    @State private var injected = false
    @State private var pid: pid_t = 0

    let dylibPath = "/var/jb/Library/MobileSubstrate/DynamicLibraries/StandoffWH.dylib"

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {

                // ── header ──
                VStack(spacing: 2) {
                    Text("StandoffWH")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("TrollStore Injector")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green.opacity(0.5))
                }
                .padding(.top, 50)
                .padding(.bottom, 20)

                // ── log output ──
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(log) { line in
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(line.color)
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    .frame(maxHeight: 220)
                    .padding(.horizontal, 20)
                    .onChange(of: log.count) { _ in
                        if let last = log.last { proxy.scrollTo(last.id) }
                    }
                }

                Spacer()

                // ── pid status ──
                if pid > 0 {
                    Text("Standoff 2 · PID \(pid)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(.bottom, 8)
                }

                // ── inject button ──
                Button(action: doInject) {
                    HStack(spacing: 10) {
                        Image(systemName: injected ? "checkmark.shield.fill" : "bolt.fill")
                        Text(injected ? "INJECTED ✓" : "INJECT WH")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(injected ? Color.green : Color(red: 0.1, green: 0.9, blue: 0.3))
                    .cornerRadius(14)
                }
                .disabled(injected)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // ── respring ──
                Button("Respring SpringBoard") {
                    addLog("Respringing...", .gray)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        _ = Foundation.Process.run(URL(fileURLWithPath: "/var/jb/usr/bin/sbreload"), arguments: [])
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.bottom, 40)
            }
        }
        .onAppear { scanProcess() }
    }

    func scanProcess() {
        addLog("[*] Scanning for Standoff 2...", .cyan)
        let p = findPID(name: "standoff2")
        if p > 0 {
            pid = p
            addLog("[+] Found: PID \(p)", .green)
        } else {
            addLog("[-] Not running. Launch the game first.", .red)
        }

        // check dylib
        if FileManager.default.fileExists(atPath: dylibPath) {
            addLog("[+] Dylib found at \(dylibPath)", .green)
        } else {
            addLog("[!] Dylib NOT found — install tweak .deb first", .orange)
        }
    }

    func doInject() {
        let p = findPID(name: "standoff2")
        guard p > 0 else {
            addLog("[-] Standoff 2 not running!", .red)
            return
        }
        pid = p
        addLog("[*] Injecting into PID \(p)...", .yellow)

        DispatchQueue.global().async {
            let result = injectDylib(pid: p, dylibPath: dylibPath)
            DispatchQueue.main.async {
                if result == "OK" {
                    injected = true
                    addLog("[+] Injected successfully!", .green)
                    addLog("[*] Switch to Standoff 2", .cyan)
                    addLog("[*] Menu appears in ~2 sec", .cyan)
                } else {
                    addLog("[!] \(result)", .red)
                }
            }
        }
    }

    func addLog(_ text: String, _ color: Color) {
        log.append(LogLine(text: text, color: color))
    }
}
