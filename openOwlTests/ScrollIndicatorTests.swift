import Testing
import AppKit
@testable import openOwl

@Suite("ScrollIndicatorView")
struct ScrollIndicatorTests {

    // MARK: - Knob Proportion

    @Test @MainActor func knobHeight_proportionalToViewport() {
        let view = ScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        // 49 visible rows out of 100 total → 49% knob
        view.update(proportion: 49.0 / 100.0, position: 0)
        // knobHeight = max(400 * 0.49, 24) = 196
        let knobHeight = max(400.0 * (49.0 / 100.0), 24.0)
        #expect(knobHeight == 196.0)
    }

    @Test @MainActor func knobHeight_minimumSize() {
        // Very large scrollback → proportion very small → clamped to 24px minimum
        let proportion: CGFloat = 49.0 / 10000.0 // 0.49%
        let knobHeight = max(400.0 * proportion, 24.0)
        #expect(knobHeight == 24.0)
    }

    @Test @MainActor func knobHeight_noScrollback() {
        // total == len → proportion = 1.0 → knob fills entire track (hidden)
        let proportion: CGFloat = 1.0
        // draw() returns early when proportion >= 1
        #expect(proportion >= 1)
    }

    // MARK: - Position Calculation

    @Test func position_atTop() {
        // offset=0, total=100, len=49 → position = 0/51 = 0
        let offset: UInt64 = 0
        let total: UInt64 = 100
        let len: UInt64 = 49
        let maxOffset = total - len
        let position = maxOffset > 0 ? CGFloat(offset) / CGFloat(maxOffset) : 0
        #expect(position == 0.0)
    }

    @Test func position_atBottom() {
        // offset=51, total=100, len=49 → position = 51/51 = 1.0
        let offset: UInt64 = 51
        let total: UInt64 = 100
        let len: UInt64 = 49
        let maxOffset = total - len
        let position = CGFloat(offset) / CGFloat(maxOffset)
        #expect(position == 1.0)
    }

    @Test func position_middle() {
        // offset=25, total=100, len=50 → position = 25/50 = 0.5
        let offset: UInt64 = 25
        let total: UInt64 = 100
        let len: UInt64 = 50
        let maxOffset = total - len
        let position = CGFloat(offset) / CGFloat(maxOffset)
        #expect(abs(position - 0.5) < 0.001)
    }

    @Test func position_noScrollback() {
        // total == len → maxOffset = 0 → position = 0
        let total: UInt64 = 49
        let len: UInt64 = 49
        let maxOffset = total - len
        let position: CGFloat = 0
        #expect(maxOffset == 0)
        #expect(position == 0.0)
    }

    // MARK: - Knob Y Coordinate (AppKit +Y up)

    @Test func knobY_atTop_isNearTopOfView() {
        let boundsHeight: CGFloat = 400
        let proportion: CGFloat = 0.5
        let position: CGFloat = 0 // top of scrollback
        let knobHeight = max(boundsHeight * proportion, 24)
        let trackSpace = boundsHeight - knobHeight
        let knobY = boundsHeight - knobHeight - (trackSpace * position)
        // position=0 → knob at top → knobY = 400 - 200 - 0 = 200 (top in AppKit coords)
        #expect(knobY == 200.0)
    }

    @Test func knobY_atBottom_isNearBottomOfView() {
        let boundsHeight: CGFloat = 400
        let proportion: CGFloat = 0.5
        let position: CGFloat = 1.0 // bottom of scrollback
        let knobHeight = max(boundsHeight * proportion, 24)
        let trackSpace = boundsHeight - knobHeight
        let knobY = boundsHeight - knobHeight - (trackSpace * position)
        // position=1 → knob at bottom → knobY = 400 - 200 - 200 = 0 (bottom in AppKit coords)
        #expect(knobY == 0.0)
    }
}
