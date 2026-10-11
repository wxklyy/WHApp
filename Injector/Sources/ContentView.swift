import SwiftUI

// dylib path on Dopamine rootless
let DYLIB_PATH = "/var/jb/Library/MobileSubstrate/DynamicLibraries/StandoffWH.dylib"
let TARGET_BUNDLE = "com.axlebolt.standoff2"

struct ContentView: View {
    @State private var status: String = "Ready"
    @State private var statusColor: Color = .gray
    @State private var isInjected: Bool = false
    @State private var pid: Int32 = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {

                // header
                VStack(spacing: 4) {
                    Text("StandoffWH")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("Wallhack Injector")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.green.opacity(0.6))
                }
                .padding(.top, 40)

                // status box
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(status)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    if pid != 0 {
                        Text("PID: \(pid)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)

                Spacer()

                // main inject button
                Button(action: inject) {
                    HStack(spacing: 12) {
                        Image(systemName: isInjected ? "checkmark.circle.fill" : "bolt.fill")
                        Text(isInjected ? "INJECTED" : "INJECT")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(isInjected ? Color.green : Color.green.opacity(0.85))
                    .cornerRadius(14)
                }
                .padding(.horizontal, 30)
                .disabled(isInjected)

                // respring button (if needed)
                Button(action: respring) {
                    Text("Respring")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            checkProcess()
        }
    }

    // ── check if standoff2 is running ──
    func checkProcess() {
        let p = getPID(bundle: TARGET_BUNDLE)
        if p > 0 {
            pid = p
            setStatus("Standoff 2 running (PID \(p))", color: .yellow)
        } else {
            setStatus("Launch Standoff 2 first", color: .red)
        }
    }

    // ── main injection logic ──
    func inject() {
        let p = getPID(bundle: TARGET_BUNDLE)
        guard p > 0 else {
            setStatus("Standoff 2 not running!", color: .red)
            return
        }
        pid = p

        // check dylib exists
        guard FileManager.default.fileExists(atPath: DYLIB_PATH) else {
            setStatus("Dylib not found at \(DYLIB_PATH)", color: .red)
            return
        }

        setStatus("Injecting into PID \(p)...", color: .yellow)

        DispatchQueue.global().async {
            // use ellekit inject (available on Dopamine)
            let result = runCommand("/var/jb/usr/bin/inject", args: ["-p", "\(p)", DYLIB_PATH])

            DispatchQueue.main.async {
                if result.exitCode == 0 {
                    isInjected = true
                    setStatus("Injected! Switch to Standoff 2", color: .green)
                } else {
                    // fallback: try cycript inject or dlopen via helper
                    let r2 = runCommand("/var/jb/usr/bin/ellekit-inject", args: ["\(p)", DYLIB_PATH])
                    if r2.exitCode == 0 {
                        isInjected = true
                        setStatus("Injected via ElleKit!", color: .green)
                    } else {
                        setStatus("Error: \(result.stderr.isEmpty ? r2.stderr : result.stderr)", color: .red)
                    }
                }
            }
        }
    }

    func respring() {
        _ = runCommand("/var/jb/usr/bin/sbreload", args: [])
    }

    func setStatus(_ msg: String, color: Color) {
        status = msg
        statusColor = color
    }
}

// ── get PID by bundle ID using sysctl ──
func getPID(bundle: String) -> Int32 {
    // try by process name first
    let names = ["standoff2", "Standoff2", "Standoff 2"]
    for name in names {
        let p = pidByName(name)
        if p > 0 { return p }
    }
    return 0
}

func pidByName(_ name: String) -> Int32 {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size: Int = 0

    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return 0 }

    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return 0 }

    for proc in procs {
        var p = proc
        let procName = withUnsafeBytes(of: &p.kp_proc.p_comm) { bytes in
            bytes.prefix(while: { $0 != 0 }).map { Character(UnicodeScalar($0)) }
        }
        let s = String(procName)
        if s.lowercased().contains(name.lowercased()) {
            return proc.kp_proc.p_pid
        }
    }
    return 0
}

// ── run a shell command, return exit code + output ──
struct CmdResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

func runCommand(_ path: String, args: [String]) -> CmdResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return CmdResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
    }

    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CmdResult(exitCode: task.terminationStatus, stdout: out, stderr: err)
}
