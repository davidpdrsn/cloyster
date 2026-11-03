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
