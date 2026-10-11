import SwiftUI

// dylib bundled inside WHApp.app itself — no .deb needed
let DYLIB_PATH: String = {
    // look for dylib in app bundle resources or root
    if let path = Bundle.main.path(forResource: "StandoffWH", ofType: "dylib") {
        return path
    }
    let direct = Bundle.main.bundlePath + "/StandoffWH.dylib"
    if FileManager.default.fileExists(atPath: direct) {
        return direct
    }
    // fallback to MobileSubstrate path if .deb is installed
    return "/var/jb/Library/MobileSubstrate/DynamicLibraries/StandoffWH.dylib"
}()
let TARGET_PROCESS = "StandRiseRE"

struct ContentView: View {
    @State private var log: [LogLine] = []
    @State private var injected = false
    @State private var pid: pid_t = 0

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
                Button("Respring") {
                    addLog("[*] Respringing...", .gray)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        do_respring()
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
        addLog("[*] Scanning for \(TARGET_PROCESS)...", .cyan)

        let p = find_pid(TARGET_PROCESS)
        if p > 0 {
            pid = p
            addLog("[+] Found: PID \(p)", .green)
        } else {
            addLog("[-] Not running — launch game first", .red)
        }

        if FileManager.default.fileExists(atPath: DYLIB_PATH) {
            let src = DYLIB_PATH.contains(".app") ? "bundled" : "deb"
            addLog("[+] Dylib OK (\(src))", .green)
        } else {
            addLog("[!] Dylib missing from bundle", .orange)
        }
    }

    func doInject() {
        let p = find_pid(TARGET_PROCESS)
        guard p > 0 else {
            addLog("[-] \(TARGET_PROCESS) not running!", .red)
            return
        }
        pid = p
        addLog("[*] Injecting into PID \(p)...", .yellow)

        DispatchQueue.global().async {
            let err = inject_dylib(p, DYLIB_PATH)
            DispatchQueue.main.async {
                if err == nil {
                    injected = true
                    addLog("[+] Injected!", .green)
                    addLog("[*] Switch to Standoff 2", .cyan)
                    addLog("[*] WH menu appears in ~2s", .cyan)
                } else {
                    let msg = String(cString: err!)
                    addLog("[!] \(msg)", .red)
                }
            }
        }
    }

    func addLog(_ text: String, _ color: Color) {
        log.append(LogLine(text: text, color: color))
    }
}
