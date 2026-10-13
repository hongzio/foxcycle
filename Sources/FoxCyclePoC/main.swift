import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: foxcycle-poc <command> [options]

  list    Dump Firefox processes, AX windows, the ring, and on-screen order.
          [--top 12]
  bench   Cycle the ring automatically and verify every switch.
          [--strategy all] [--dir both|fwd|bwd] [--count 50] [--timeout-ms 1000]
          [--settle-ms 200] [--interval-ms 150] [--delay-s 3] [--verbose]
  tap     Intercept ⌘` / ⌘⇧` while Firefox is frontmost. Ctrl-C prints a summary.
          [--strategy s1] [--max-pending 8] [--trust-last-ms 750] [--debug-keys]

common: [--log-file PATH]  append output to PATH (for runs launched via `open`)

strategies: \(ActivationStrategy.presets.map(\.summary).joined(separator: ", "))
            or a custom chain of \(ActivationOp.allCases.map(\.rawValue).joined(separator: "|")) joined by '+'
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["list", "bench", "tap"].contains(command) else {
    print(usage)
    exit(2)
}
let options = Options(arguments.dropFirst())

// Launched via `open` (as an .app) there is no terminal to print to.
let logFile = options.string("log-file", default: "")
if !logFile.isEmpty {
    freopen(logFile, "a", stdout)
    freopen(logFile, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
}

print("[\(timeFormatter.string(from: Date()))] \(command) · bundle \(Bundle.main.bundleIdentifier ?? "none (CLI)")"
    + " · accessibility \(AXIsProcessTrusted()) · listen \(CGPreflightListenEventAccess())"
    + " · post \(CGPreflightPostEventAccess())")

guard AXIsProcessTrusted() else {
    // Triggers the system prompt for this process (or its responsible app when run from a terminal).
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    print("Accessibility permission is required (System Settings → Privacy & Security → Accessibility).")
    exit(1)
}
AX.setGlobalTimeout(seconds: 0.25)

// Run as a Dock-less accessory app so activation behaves like the eventual LSUIElement agent.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

var tapController: TapController?
var signalSources: [DispatchSourceSignal] = []

switch command {
case "list":
    Thread { ListCommand.run(options); exit(0) }.start()
case "bench":
    Thread { BenchCommand.run(options); exit(0) }.start()
default:
    guard let strategy = ActivationStrategy.parse(options.string("strategy", default: "s1"))?.first else {
        print(usage)
        exit(2)
    }
    let controller = TapController(
        strategy: strategy,
        maxPending: options.int("max-pending", default: 8),
        trustLastTargetMs: Double(options.int("trust-last-ms", default: 750)),
        debugKeys: options.flag("debug-keys")
    )
    tapController = controller
    controller.start()
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            tapController?.printSummary()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

application.run()
