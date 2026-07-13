import Foundation
@testable import Dory

struct StrictCommitRequest: Equatable {
    let containerID: String
    let repo: String
    let tag: String
    let labels: [String: String]
    let pause: Bool
}

@MainActor
extension StrictMigrationRuntime {
    func commit(
        containerID: String,
        repo: String,
        tag: String,
        labels: [String: String],
        pause: Bool
    ) async throws -> String {
        commitRequests.append(StrictCommitRequest(
            containerID: containerID,
            repo: repo,
            tag: tag,
            labels: labels,
            pause: pause
        ))
        let imageID = "sha256:" + String(format: "%064x", commitRequests.count + 12)
        snapshotValue.images.append(DockerImage(
            repository: repo,
            tag: tag,
            imageID: imageID,
            size: "1 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1_024,
            labels: labels
        ))
        return imageID
    }
}
