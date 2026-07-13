import Darwin
import DoryCore
import DorydKit
import Foundation

private let usage = "usage: dory-dataplane-proxy --listen PATH --backend PATH [--gpu-supported]"

private func fail(_ message: String, status: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("dory-dataplane-proxy: \(message)\n".utf8))
    exit(status)
}

var listenPath: String?
var backendPath: String?
var gpuSupported = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--listen":
        listenPath = arguments.next()
    case "--backend":
        backendPath = arguments.next()
    case "--gpu-supported":
        gpuSupported = true
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        fail("unknown argument \(argument)\n\(usage)")
    }
}

guard let listenPath, !listenPath.isEmpty else { fail("--listen is required\n\(usage)") }
guard let backendPath, !backendPath.isEmpty else { fail("--backend is required\n\(usage)") }
guard listenPath != backendPath else { fail("listen and backend paths must be different") }
guard listenPath.hasPrefix("/") && backendPath.hasPrefix("/") else {
    fail("listen and backend paths must be absolute")
}

// Docker clients frequently close a stream once they have the response they need. Rust handles
// that as an ordinary connection close; prevent a process-wide SIGPIPE before the handoff.
_ = signal(SIGPIPE, SIG_IGN)

let listener = DorySocket(path: listenPath)
let listenerFD: Int32
do {
    listenerFD = try listener.bind()
} catch {
    fail("cannot bind \(listenPath): \(error)", status: 1)
}

let dataplane = DoryCore.startDockerDataplane(
    listenFD: listenerFD,
    dockerdSocketPath: backendPath,
    gpuSupported: gpuSupported
)
FileHandle.standardError.write(Data("dory-dataplane-proxy: \(listenPath) -> \(backendPath)\n".utf8))

// Rust owns the listener fd after startDockerDataplane. Keep its lifetime handle alive until the
// process is terminated by the standalone runtime supervisor.
withExtendedLifetime(dataplane) {
    dispatchMain()
}
