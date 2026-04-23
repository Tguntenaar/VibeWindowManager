//
//  VibeWindowManagerTests.swift
//  VibeWindowManagerTests
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import VibeWindowManager

struct WindowLayoutEngineTests {
    @Test func equalColumnsFillsWidth() {
        let vf = CGRect(x: 100, y: 200, width: 1000, height: 400)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .equalColumns(2), count: 2)
        #expect(slots.count == 2)
        #expect(abs(slots[0].minX - vf.minX) < 1)
        #expect(abs((slots[0].maxX - slots[1].minX)) < 2)
        #expect(abs((slots[0].width + slots[1].width) - vf.width) < 2)
    }

    @Test func equalRowsFillsHeight() {
        let vf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .equalRows(2), count: 2)
        #expect(slots.count == 2)
        #expect(abs((slots[0].height + slots[1].height) - vf.height) < 2)
    }

    @Test func gridFourRects() {
        let vf = CGRect(x: 0, y: 0, width: 400, height: 400)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .grid(4), count: 4)
        #expect(slots.count == 4)
        for s in slots {
            #expect(s.minX >= vf.minX)
            #expect(s.minY >= vf.minY)
            #expect(s.maxX <= vf.maxX + 0.1)
            #expect(s.maxY <= vf.maxY + 0.1)
        }
    }

    @Test func cascadeStaysInVisibleFrame() {
        let vf = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frames = WindowLayoutEngine.cascadeFrames(
            visibleFrame: vf,
            count: 3,
            insetStep: 30,
            margin: 8
        )
        #expect(frames.count == 3)
        for f in frames {
            #expect(f.minX >= vf.minX)
            #expect(f.minY >= vf.minY)
            #expect(f.maxX <= vf.maxX + 0.1)
            #expect(f.maxY <= vf.maxY + 0.1)
        }
    }

    @Test func cascadeLastWindowSitsTopRight() {
        let vf = CGRect(x: 100, y: 100, width: 900, height: 700)
        let frames = WindowLayoutEngine.cascadeFrames(
            visibleFrame: vf,
            count: 4,
            insetStep: 30,
            margin: 8
        )

        #expect(frames.count == 4)
        let last = frames[3]
        let previous = frames[2]

        #expect(abs(last.maxX - (vf.maxX - 8)) < 1.0)
        #expect(abs(last.maxY - (vf.maxY - 8)) < 1.0)
        #expect(abs((last.minX - previous.minX) - 30) < 1.0)
        #expect(abs((last.minY - previous.minY) - 30) < 1.0)
    }

    @Test func fiveWindowColumnsProduceFiveRects() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .equalColumns(5), count: 5)

        #expect(slots.count == 5)
        #expect(abs(slots.map(\.width).reduce(0, +) - vf.width) < 2)
    }

    @Test func fiveWindowGridProducesFiveRects() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .grid(5), count: 5)

        #expect(slots.count == 5)
        for slot in slots {
            #expect(slot.minX >= vf.minX)
            #expect(slot.minY >= vf.minY)
            #expect(slot.maxX <= vf.maxX + 0.1)
            #expect(slot.maxY <= vf.maxY + 0.1)
        }
    }

    @Test func suggestedModesFollowWindowCount() {
        #expect(TileMode.suggestedModes(forWindowCount: 0).isEmpty)
        #expect(TileMode.suggestedModes(forWindowCount: 2) == [.equalColumns(2), .equalRows(2)])
        #expect(TileMode.suggestedModes(forWindowCount: 3) == [.onePlusTwo, .grid(3), .equalColumns(3), .equalRows(3)])
        #expect(TileMode.suggestedModes(forWindowCount: 5) == [.grid(5), .equalColumns(5)])
    }

    @Test func appKitFrameConvertsToAXTopLeftPosition() {
        let rect = CGRect(x: 100, y: 700, width: 400, height: 150)

        let point = ScreenGeometry.axPosition(
            forAppKitFrame: rect,
            menuBarScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(point.x == 100)
        #expect(point.y == 50)
    }

    @Test func stageManagerReservesLeadingStripOnMenuBarDisplay() {
        let layoutFrame = ScreenGeometry.layoutFrame(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            menuBarScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isStageManagerEnabled: true
        )

        #expect(layoutFrame.minX == StageManagerSupport.reservedLeadingStripWidth)
        #expect(layoutFrame.width == 1440 - StageManagerSupport.reservedLeadingStripWidth)
    }
}
