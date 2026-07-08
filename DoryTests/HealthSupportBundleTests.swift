import Foundation
import Testing
@testable import Dory

struct HealthSupportBundleTests {
    @Test func supportBundleResultDecodesCLIContract() throws {
        let json = """
        {
          "schema": "dev.dory.support.bundle",
          "version": 1,
          "path": "/Users/me/.dory/support/dory-support-20260708.zip",
          "redacted": true,
          "share": "Attach this zip to your GitHub issue instead of screenshots."
        }
        """

        let bundle = try JSONDecoder().decode(SupportBundleResult.self, from: Data(json.utf8))

        #expect(bundle.schema == "dev.dory.support.bundle")
        #expect(bundle.version == 1)
        #expect(bundle.path.hasSuffix(".zip"))
        #expect(bundle.redacted)
        #expect(bundle.share.contains("GitHub issue"))
    }
}
