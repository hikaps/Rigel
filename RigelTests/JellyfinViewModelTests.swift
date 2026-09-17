import XCTest
import ComposeApp
@testable import Rigel

/// A disconnect during in-flight Jellyfin requests cancels the tasks, and a
/// cancelled task returns before clearing its own flag. disconnect() must
/// therefore reset the activity flags itself, or the UI stays latched busy.
@MainActor
final class JellyfinViewModelTests: XCTestCase {

    func testDisconnectResetsActivityFlagsWhileRequestsInFlight() {
        let model = JellyfinViewModel()
        model.loadLibrary(at: nil)
        model.searchText = "star"
        model.search()
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.searchBusy)

        model.disconnect()

        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.searchBusy)
    }
}
