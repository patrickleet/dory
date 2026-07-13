import DoryCore
import XCTest
@testable import DorydKit

final class MachineRecipeProvisionerTests: XCTestCase {
    func testBuiltInRecipeAliasesResolveToAlpineRecipes() throws {
        let cases: [(String, String, String)] = [
            ("node", "node", "node --version"),
            ("python", "python-ml", "python3 --version"),
            ("go", "go", "go version"),
            ("java", "java", "java -version"),
            ("ruby", "ruby", "ruby --version"),
            ("rust", "rust", "cargo --version"),
            ("devops", "devops", "docker --version"),
            ("docker-cli", "docker-host", "docker --version"),
            ("kubectl", "k8s-lab", "kubectl version"),
        ]

        for (input, expectedID, verifyNeedle) in cases {
            let recipe = try MachineRecipeProvisioner.recipe(id: input)
            XCTAssertEqual(recipe.id, expectedID, input)
            XCTAssertTrue(recipe.verifyCommand.contains(verifyNeedle), input)
            XCTAssertGreaterThan(recipe.timeoutMs, 0, input)
        }
    }

    func testRequiredProvisioningStageRejectsNonzeroExitWithStderr() {
        let result = DoryExecResult(
            exitCode: 17,
            stdout: Data(),
            stderr: Data("missing required configuration".utf8),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )

        XCTAssertThrowsError(
            try MachineRecipeProvisioner.requireSuccess(result, recipe: "k8s-lab", stage: "install")
        ) { error in
            XCTAssertEqual(
                error as? MachineRecipeProvisionError,
                .commandFailed(
                    recipe: "k8s-lab",
                    stage: "install",
                    exitCode: 17,
                    stderr: "missing required configuration"
                )
            )
        }
    }

    func testRequiredProvisioningStageRejectsTimeoutEvenWithZeroExit() {
        let result = DoryExecResult(
            exitCode: 0,
            stdout: Data(),
            stderr: Data(),
            timedOut: true,
            stdoutTruncated: false,
            stderrTruncated: false
        )

        XCTAssertThrowsError(
            try MachineRecipeProvisioner.requireSuccess(result, recipe: "rust", stage: "verify")
        ) { error in
            XCTAssertEqual(
                error as? MachineRecipeProvisionError,
                .commandFailed(recipe: "rust", stage: "verify", exitCode: 124, stderr: "")
            )
        }
    }
}
