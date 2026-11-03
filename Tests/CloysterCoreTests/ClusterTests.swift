import Testing
import CloysterCore

private let frame = Rect(x: 100, y: 100, width: 1012, height: 600)

private func pair() -> Cluster<String> {
    Cluster(root: .split(.horizontal, [.window("a"), .window("b")]), frame: frame)
}

/// a | b
/// --+
/// c | (b spans both rows)
private func grid() -> Cluster<String> {
    Cluster(
        root: .split(.horizontal, [
            .split(.vertical, [.window("a"), .window("c")]),
            .window("b"),
        ]),
        frame: frame
    )
}

@Test func splitsEvenlyAroundGap() {
    let f = pair().frames
    #expect(f["a"] == Rect(x: 100, y: 100, width: 500, height: 600))
    #expect(f["b"] == Rect(x: 612, y: 100, width: 500, height: 600))
}

@Test func dividerKeepsCombinedSize() {
    var c = pair()
    c.moveDivider(c.dividers[0], by: 50)
    let f = c.frames
    #expect(f["a"]?.width == 550)
    #expect(f["b"] == Rect(x: 662, y: 100, width: 450, height: 600))
}

@Test func dividerStopsAtMinSize() {
    var c = pair()
    let moved = c.moveDivider(c.dividers[0], by: 1000)
    #expect(moved == 380)
    #expect(c.frames["b"]?.width == 120)
    #expect(c.frames["b"].map { $0.x + $0.width } == 1112)
}

@Test func draggingMovesWholeCluster() {
    var c = pair()
    c.update("b", to: Rect(x: 712, y: 150, width: 500, height: 600))
    #expect(c.frames["a"] == Rect(x: 200, y: 150, width: 500, height: 600))
}

@Test func widerOuterEdgeGrowsOnlyThatWindow() {
    var c = pair()
    c.update("b", to: Rect(x: 612, y: 100, width: 600, height: 600))
    let f = c.frames
    #expect(f["a"] == Rect(x: 100, y: 100, width: 500, height: 600))
    #expect(f["b"] == Rect(x: 612, y: 100, width: 600, height: 600))
}

@Test func leftEdgeGrowthKeepsRightEdgeFixed() {
    var c = pair()
    c.update("a", to: Rect(x: 50, y: 100, width: 550, height: 600))
    let f = c.frames
    #expect(f["a"] == Rect(x: 50, y: 100, width: 550, height: 600))
    #expect(f["b"] == Rect(x: 612, y: 100, width: 500, height: 600))
}

@Test func tallerWindowGrowsItsRow() {
    var c = pair()
    c.update("a", to: Rect(x: 100, y: 100, width: 500, height: 700))
    #expect(c.frames["b"] == Rect(x: 612, y: 100, width: 500, height: 700))
}

@Test func topEdgeGrowsRowAndKeepsBottomFixed() {
    var c = pair()
    c.update("b", to: Rect(x: 612, y: 60, width: 500, height: 640))
    #expect(c.frames["a"] == Rect(x: 100, y: 60, width: 500, height: 640))
}

@Test func widerWindowGrowsItsColumnOnly() {
    var c = grid()
    let b = c.frames["b"]!
    let a = c.frames["a"]!
    c.update("a", to: Rect(x: a.x - 40, y: a.y, width: a.width + 40, height: a.height))
    let f = c.frames
    #expect(f["a"]?.width == a.width + 40)
    #expect(f["c"]?.width == a.width + 40)
    #expect(f["b"] == b)
}

@Test func tallerWindowInStackGrowsOppositeColumn() {
    var c = grid()
    let a = c.frames["a"]!
    let cFrame = c.frames["c"]!
    c.update("c", to: Rect(x: cFrame.x, y: cFrame.y, width: cFrame.width, height: cFrame.height + 80))
    let f = c.frames
    #expect(f["a"] == a)
    #expect(f["c"]?.height == cFrame.height + 80)
    #expect(f["b"]?.height == 680)
}

@Test func shrinkStopsAtMinSizeOfColumn() {
    var c = grid()
    let a = c.frames["a"]!
    c.update("a", to: Rect(x: a.x, y: a.y, width: 10, height: a.height))
    #expect(c.frames["a"]?.width == 120)
    #expect(c.frames["c"]?.width == 120)
}

@Test func nestedDividerOnlyAffectsItsSplit() {
    var c = grid()
    let b = c.frames["b"]!
    let divider = c.dividers.first { $0.axis == .vertical }!
    c.moveDivider(divider, by: 30)
    let f = c.frames
    #expect(f["b"] == b)
    #expect(f["a"]!.height + f["c"]!.height + 12 == 600)
}

@Test func removingWindowGivesSpaceToNeighbour() {
    var c = grid()
    let removed = c.remove("c")
    #expect(removed)
    let f = c.frames
    #expect(f["a"]?.height == 600)
    #expect(f["b"]?.height == 600)
    #expect(c.dividers.count == 1)
}

@Test func removingFirstWindowKeepsOuterFrame() {
    var c = pair()
    let removed = c.remove("a")
    #expect(removed)
    #expect(c.frames["b"] == frame)
}

@Test func cannotRemoveLastWindow() {
    var c = Cluster<String>(root: .window("a"), frame: frame)
    let removed = c.remove("a")
    #expect(!removed)
}

@Test func parsesNestedLayout() {
    let node = Node<String>.parse("h(Safari,v(Google Chrome,123))")
    #expect(node?.windowIDs == ["Safari", "Google Chrome", "123"])
    guard case .split(.horizontal, let children)? = node?.content else {
        Issue.record("expected a horizontal split")
        return
    }
    guard case .split(.vertical, _) = children[1].content else {
        Issue.record("expected a vertical split")
        return
    }
}

@Test func rejectsMalformedLayouts() {
    #expect(Node<String>.parse("h(a,b") == nil)
    #expect(Node<String>.parse("h(a)") == nil)
    #expect(Node<String>.parse("h(a,)") == nil)
    #expect(Node<String>.parse("h(a,b)c") == nil)
    #expect(Node<String>.parse("") == nil)
}

private let incoming = Rect(x: 900, y: 500, width: 300, height: 200)

@Test func attachingKeepsTargetAndTakesItsHeight() {
    var c = Cluster<String>(root: .window("a"), frame: Rect(x: 100, y: 100, width: 500, height: 600))
    c.attach("n", size: incoming, at: Drop(target: "a", side: .right))
    let f = c.frames
    #expect(f["a"] == Rect(x: 100, y: 100, width: 500, height: 600))
    #expect(f["n"] == Rect(x: 612, y: 100, width: 300, height: 600))
}

@Test func attachingLeftKeepsTargetInPlace() {
    var c = Cluster<String>(root: .window("a"), frame: Rect(x: 500, y: 100, width: 500, height: 600))
    c.attach("n", size: incoming, at: Drop(target: "a", side: .left))
    let f = c.frames
    #expect(f["a"] == Rect(x: 500, y: 100, width: 500, height: 600))
    #expect(f["n"] == Rect(x: 188, y: 100, width: 300, height: 600))
}

@Test func attachingBelowKeepsHeightAndTakesWidth() {
    var c = Cluster<String>(root: .window("a"), frame: Rect(x: 100, y: 100, width: 500, height: 300))
    c.attach("n", size: incoming, at: Drop(target: "a", side: .bottom))
    let f = c.frames
    #expect(f["a"] == Rect(x: 100, y: 100, width: 500, height: 300))
    #expect(f["n"] == Rect(x: 100, y: 412, width: 500, height: 200))
}

@Test func attachingInsideRowPushesLaterWindows() {
    var c = pair()
    c.attach("n", size: incoming, at: Drop(target: "a", side: .right))
    let f = c.frames
    #expect(f["a"] == Rect(x: 100, y: 100, width: 500, height: 600))
    #expect(f["n"] == Rect(x: 612, y: 100, width: 300, height: 600))
    #expect(f["b"] == Rect(x: 924, y: 100, width: 500, height: 600))
    #expect(c.dividers.count == 2)
    #expect(c.dividers.allSatisfy { $0.path.isEmpty })
}

@Test func attachingBesideStackedWindowWidensColumn() {
    var c = grid()
    let a = c.frames["a"]!
    let b = c.frames["b"]!
    c.attach("n", size: incoming, at: Drop(target: "a", side: .right))
    let f = c.frames
    #expect(f["a"] == a)
    #expect(f["n"]?.height == a.height)
    #expect(f["c"]?.width == a.width + 312)
    #expect(f["b"]?.x == b.x + 312)
    #expect(f["b"]?.width == b.width)
}

@Test func attachingAlongOuterSideSpansCluster() {
    var c = pair()
    c.attach("n", size: incoming, at: Drop(target: nil, side: .bottom))
    let f = c.frames
    #expect(f["n"] == Rect(x: 100, y: 712, width: 1012, height: 200))
    #expect(f["a"]?.height == 600)
}

@Test func attachingAlongOuterLeftKeepsExistingWindowsInPlace() {
    var c = pair()
    let before = c.frames
    c.attach("n", size: incoming, at: Drop(target: nil, side: .left))
    let f = c.frames
    #expect(f["a"] == before["a"])
    #expect(f["b"] == before["b"])
    #expect(f["n"] == Rect(x: -212, y: 100, width: 300, height: 600))
}

@Test func attachedWindowHonoursMinSize() {
    var c = Cluster<String>(root: .window("a"), frame: Rect(x: 0, y: 0, width: 500, height: 600))
    c.attach("n", size: Rect(x: 0, y: 0, width: 40, height: 40), at: Drop(target: "a", side: .right))
    #expect(c.frames["n"]?.width == 120)
}

@Test func dropPicksOneSideOfTheWindowUnderTheCursor() {
    let c = Cluster<String>(root: .window("a"), frame: Rect(x: 0, y: 0, width: 1000, height: 600))
    #expect(c.drop(x: 950, y: 300, over: "a") == Drop(target: "a", side: .right))
    #expect(c.drop(x: 50, y: 300, over: "a") == Drop(target: "a", side: .left))
    #expect(c.drop(x: 500, y: 20, over: "a") == Drop(target: "a", side: .top))
    #expect(c.drop(x: 500, y: 580, over: "a") == Drop(target: "a", side: .bottom))
}

@Test func dropNearOuterEdgeTargetsWholeSide() {
    let c = pair()
    #expect(c.drop(x: 400, y: 680, over: "a") == Drop(target: nil, side: .bottom))
    #expect(c.drop(x: 400, y: 620, over: "a") == Drop(target: "a", side: .bottom))
}

@Test func previewDoesNotChangeCluster() {
    let c = pair()
    let preview = c.preview("n", size: incoming, at: Drop(target: "b", side: .right))
    #expect(preview == Rect(x: 1124, y: 100, width: 300, height: 600))
    #expect(c.frames.count == 2)
}

@Test func previewOfWindowAlreadyInClusterMovesIt() {
    var c = pair()
    c.attach("n", size: incoming, at: Drop(target: "b", side: .right))
    let preview = c.preview("n", size: incoming, at: Drop(target: "a", side: .left))
    #expect(preview == Rect(x: -212, y: 100, width: 300, height: 600))
}
