import SwiftUI

let TARGET_PROCESS = "StandRiseRE"

let DYLIB_PATH: String = {
    if let path = Bundle.main.path(forResource: "StandoffWH", ofType: "dylib") {
        return path
    }
    let direct = Bundle.main.bundlePath + "/StandoffWH.dylib"
    if FileManager.default.fileExists(atPath: direct) {
        return direct
    }
    let frameworks = Bundle.main.bundlePath + "/Frameworks/StandoffWH.dylib"
    if FileManager.default.fileExists(atPath: frameworks) {
        return frameworks
    }
    return "/var/jb/Library/MobileSubstrate/DynamicLibraries/StandoffWH.dylib"
}()

struct TargetAppInfo {
    let appDir: String
    let binaryPath: String
    let appName: String
}

struct ContentView: View {
    @State private var log: [LogLine] = []
    @State private var injected = false
    @State private var targetFound: TargetAppInfo? = nil
    @State private var isProcessing = false

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {

                // ── Header ──
                VStack(spacing: 2) {
                    Text("StandoffWH")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("TrollStore In-Place Injector")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green.opacity(0.5))
                }
                .padding(.top, 50)
                .padding(.bottom, 20)

                // ── Console Log ──
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

                // ── Target status ──
                if let target = targetFound {
                    Text("Target: \(target.appName)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(.bottom, 8)
                } else {
                    Text("Scanning apps...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.bottom, 8)
                }

                // ── Inject Button ──
                Button(action: doInject) {
                    HStack(spacing: 10) {
                        Image(systemName: injected ? "checkmark.shield.fill" : (isProcessing ? "arrow.triangle.2.circlepath" : "bolt.fill"))
                        Text(injected ? "INJECTED ✓" : (isProcessing ? "INJECTING..." : "INJECT WH"))
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(injected ? Color.green : Color(red: 0.1, green: 0.9, blue: 0.3))
                    .cornerRadius(14)
                }
                .disabled(injected || isProcessing)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // ── Respring ──
                Button("Respring SpringBoard") {
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
        .onAppear { scanEnvironment() }
    }

    func scanEnvironment() {
        addLog("[*] Initializing injector...", .cyan)

        if FileManager.default.fileExists(atPath: DYLIB_PATH) {
            addLog("[+] StandoffWH.dylib found", .green)
        } else {
            addLog("[!] Dylib not found at path!", .red)
        }

        if let target = findTargetApp() {
            targetFound = target
            addLog("[+] Detected: \(target.appName)", .green)
            addLog("[*] Ready to inject into binary", .cyan)
        } else {
            addLog("[-] StandRiseRE.app not found in /var/containers", .orange)
        }

        let p = find_pid(TARGET_PROCESS)
        if p > 0 {
            addLog("[*] Game currently active (PID \(p))", .yellow)
        }
    }

    func findTargetApp() -> TargetAppInfo? {
        let bundleDir = "/var/containers/Bundle/Application"
        let binaryNames = [TARGET_PROCESS, "standoff2", "Standoff2"]

        guard let uuids = try? FileManager.default.contentsOfDirectory(atPath: bundleDir) else {
            return nil
        }

        for uuid in uuids {
            let containerPath = "\(bundleDir)/\(uuid)"
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: containerPath) else { continue }
            for item in items where item.hasSuffix(".app") {
                let appPath = "\(containerPath)/\(item)"
                for binName in binaryNames {
                    let bin = "\(appPath)/\(binName)"
                    if FileManager.default.fileExists(atPath: bin) {
                        return TargetAppInfo(appDir: appPath, binaryPath: bin, appName: item)
                    }
                }
            }
        }
        return nil
    }

    func doInject() {
        guard !isProcessing else { return }
        isProcessing = true

        DispatchQueue.global(qos: .userInitiated).async {
            guard let target = self.targetFound ?? self.findTargetApp() else {
                DispatchQueue.main.async {
                    self.addLog("[-] StandRiseRE.app not found on device!", .red)
                    self.isProcessing = false
                }
                return
            }

            DispatchQueue.main.async {
                self.addLog("[*] Target: \(target.binaryPath)", .cyan)
            }

            // If game is running, terminate it so new binary loads
            let p = find_pid(TARGET_PROCESS)
            if p > 0 {
                kill(p, SIGKILL)
                DispatchQueue.main.async {
                    self.addLog("[*] Terminated running game (PID \(p))", .yellow)
                }
                usleep(300000)
            }

            // 1. Copy StandoffWH.dylib into target .app bundle
            let targetDylib = "\(target.appDir)/StandoffWH.dylib"
            do {
                if FileManager.default.fileExists(atPath: targetDylib) {
                    try FileManager.default.removeItem(atPath: targetDylib)
                }
                try FileManager.default.copyItem(atPath: DYLIB_PATH, toPath: targetDylib)
                DispatchQueue.main.async {
                    self.addLog("[+] Copied StandoffWH.dylib to app bundle", .green)
                }
            } catch {
                DispatchQueue.main.async {
                    self.addLog("[-] Copy dylib failed: \(error.localizedDescription)", .red)
                    self.isProcessing = false
                }
                return
            }

            // 2. Inject LC_LOAD_DYLIB load command into Mach-O header
            let patchRes = patch_macho_add_dylib(target.binaryPath, "@executable_path/StandoffWH.dylib")
            DispatchQueue.main.async {
                if patchRes > 0 {
                    self.addLog("[+] Hooked LC_LOAD_DYLIB in Mach-O header", .green)
                } else if patchRes == 0 {
                    self.addLog("[+] StandoffWH already hooked in Mach-O", .cyan)
                } else {
                    self.addLog("[-] Mach-O patch failed: code \(patchRes)", .red)
                }
            }

            // 3. Resign with ldid
            let ldidRes = resign_binary(target.binaryPath)
            DispatchQueue.main.async {
                self.addLog("[+] Resigned binary (code \(ldidRes))", .green)
                self.injected = true
                self.isProcessing = false
                self.addLog("[✓] SUCCESS! Wallhack installed!", .green)
                self.addLog("[*] Open StandRiseRE from Home Screen!", .cyan)
            }
        }
    }

    func addLog(_ text: String, _ color: Color) {
        log.append(LogLine(text: text, color: color))
    }
}
