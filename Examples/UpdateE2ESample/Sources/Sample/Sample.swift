import AppKit
import FritCore
import FritSystem
import FritUpdate

@main
enum Sample {
    @MainActor static func main() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        print("Sample \(version) 已启动")
        if CommandLine.arguments.contains("--exit") { exit(0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = SampleDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class SampleDelegate: NSObject, NSApplicationDelegate {
    private var updater: Updater?
    private let environment = ProcessInfo.processInfo.environment
    private lazy var log = FileLog(subsystem: "io.github.whrss9527.frit.sample",
                                   fileURL: environment["SAMPLE_UPDATE_LOG"].map { URL(fileURLWithPath: $0) })
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        log.info("SAMPLE_STARTED version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier)")
        log.flush()
        if Bundle.main.object(forInfoDictionaryKey: "FritSampleFailAtStartup") as? Bool == true {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                log.info("SAMPLE_EARLY_EXIT version=\(version)")
                log.flush()
                exit(42)
            }
            return
        }
        Task {
            // 与 Meno 相同：稳定运行八秒后确认健康，提前退出的新包不能删掉旧包。
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if let rejected = Updater.finishPreviousUpdate() {
                log.info("SAMPLE_ROLLBACK rejected=\(rejected) restored=\(version)")
                log.flush()
                return
            }
            log.info("SAMPLE_HEALTHY version=\(version)")
            log.flush()
            guard environment["SAMPLE_UPDATE_URL"] != nil else { return }
            var config = UpdateConfiguration(repository: "whrss9527/frit", appName: "Sample")
            config.environmentPrefix = "SAMPLE"
            config.signer = .any
            config.strictChecks = .all
            config.installStrategy = environment["SAMPLE_INSTALL_STRATEGY"] == "atomic" ? .atomicSwap : .staged
            config.log = UpdateLogger(info: { [log] in log.info($0); log.flush() }, error: { [log] in log.error($0); log.flush() })
            let updater = Updater(configuration: config)
            self.updater = updater
            if environment["SAMPLE_UPDATE_AUTO_INSTALL"] == "1" { await updater.checkAndInstall() }
            else { _ = await updater.check(manual: true) }
            if let failure = updater.lastFailure { log.info("SAMPLE_FAILED \(failure)"); log.flush() }
        }
    }
}
