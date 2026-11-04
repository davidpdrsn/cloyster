import CloysterCore
import Testing

private let a: WindowID = 1
private let b: WindowID = 2
private let c: WindowID = 3
private let aFrame = Rect(x: 200, y: 150, width: 400, height: 300)
private let bFrame = Rect(x: 800, y: 500, width: 350, height: 250)
private let cFrame = Rect(x: 1000, y: 650, width: 300, height: 200)

private func twoWindows() -> FakeWindows {
    let fake = FakeWindows()
    fake.add(a, aFrame)
    fake.add(b, bFrame)
    return fake
}

/// `a` and `b` side by side, with `b` joined to the right of `a`.
private func joined() -> FakeWindows {
    let fake = twoWindows()
    fake.commandDrag(b, toX: 580, y: 300)
    fake.settle()
    return fake
}

@Test func commandDragJoinsAtTheNearestEdge() {
    let fake = joined()
    #expect(fake.frame(a) == aFrame)
    #expect(fake.frame(b) == Rect(x: 612, y: 150, width: 350, height: 300))
    #expect(fake.liveSurfaces.count == 1)
    #expect(fake.liveSurfaces[0].dividers.count == 1)
}

@Test func previewShowsTheLandingSpotUntilRelease() {
    let fake = twoWindows()
    fake.commandHeld = true
    fake.press(b)
    fake.move(toX: 580, y: 300)
    #expect(fake.preview == Rect(x: 612, y: 150, width: 350, height: 300))
    fake.release()
    #expect(fake.preview == nil)
}

@Test func commandCanGoDownAfterTheDragStarts() {
    let fake = twoWindows()
    fake.press(b)
    fake.move(toX: 800, y: 400)
    fake.commandHeld = true
    fake.move(toX: 580, y: 300)
    fake.release()
    fake.commandHeld = false
    fake.settle()
    #expect(fake.frame(b) == Rect(x: 612, y: 150, width: 350, height: 300))
}

@Test func plainDragNeverJoins() {
    let fake = twoWindows()
    fake.press(b)
    fake.move(toX: 580, y: 300)
    fake.release()
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
    #expect(fake.frame(a) == aFrame)
}

@Test func commandClickChangesNothing() {
    let fake = twoWindows()
    fake.commandHeld = true
    fake.press(b)
    fake.release()
    fake.commandHeld = false
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
    #expect(fake.frame(b) == bFrame)
}

@Test func middleOfAWindowDoesNotJoin() {
    let fake = twoWindows()
    fake.commandDrag(b, toX: 400, y: 300)
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
    #expect(fake.frame(a) == aFrame)
}

@Test func windowsWeCannotControlAreNotJoined() {
    let fake = twoWindows()
    fake.windows[a]!.isManageable = false
    fake.commandDrag(b, toX: 580, y: 300)
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
    #expect(fake.frame(a) == aFrame)
}

@Test func releasingCommandFirstSnapsAClusteredWindowBack() {
    let fake = joined()
    fake.commandHeld = true
    fake.press(b)
    fake.move(toX: 760, y: 600)
    fake.commandHeld = false
    fake.move(toX: 760, y: 601)
    fake.release()
    fake.settle()
    #expect(fake.manager.controllers.count == 1)
    #expect(fake.frame(a) == aFrame)
    #expect(fake.frame(b) == Rect(x: 612, y: 150, width: 350, height: 300))
}

@Test func leavingATwoWindowClusterLeavesThePartnerAlone() {
    let fake = joined()
    fake.commandDrag(b, toX: 1200, y: 800)
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
    #expect(fake.frame(a) == aFrame)
    #expect(fake.liveSurfaces.isEmpty)
}

@Test func commandDuringAClusterDragStillLeaves() {
    let fake = joined()
    fake.press(b)
    fake.move(toX: 800, y: 200)
    fake.commandHeld = true
    fake.move(toX: 1200, y: 800)
    fake.release()
    fake.commandHeld = false
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
}

@Test func joinIgnoresWhereTheWindowWasDropped() {
    // Regression: nothing has landed yet at release, so the joined window is still where it was
    // dropped. That used to look like a user drag and squash the whole cluster.
    let fake = joined()
    fake.add(c, cFrame)
    fake.commandDrag(c, toX: 400, y: 430)
    #expect(fake.hasPendingWrites)
    fake.manager.poll()
    fake.settle()
    #expect(fake.frame(a) == aFrame)
    #expect(fake.frame(b) == Rect(x: 612, y: 150, width: 350, height: 300))
    #expect(fake.frame(c) == Rect(x: 200, y: 462, width: 762, height: 200))
}

@Test func thirdWindowJoinsOneWindowAndGrowsTheRow() {
    let fake = joined()
    fake.add(c, cFrame)
    fake.commandDrag(c, toX: 400, y: 380)
    fake.settle()
    #expect(fake.frame(a) == aFrame)
    #expect(fake.frame(c) == Rect(x: 200, y: 462, width: 400, height: 200))
    #expect(fake.frame(b) == Rect(x: 612, y: 150, width: 350, height: 512))
}

@Test func followersCatchUpWithoutMovingTheLeader() {
    let fake = joined()
    fake.press(b)
    fake.move(toX: 900, y: 300)
    fake.move(toX: 950, y: 350)
    let leader = fake.frame(b)
    #expect(!fake.hasPendingWrite(for: b))
    fake.deliverOne()
    #expect(fake.frame(b) == leader)
    fake.release()
    fake.settle()
    #expect(fake.frame(b) == leader)
    #expect(fake.frame(a).x == leader.x - 412)
    #expect(fake.frame(a).y == leader.y)
}

@Test func snappingWindowsKeepRowsEqualWhateverTheOrder() {
    // Regression: which window was looked at first decided whether the row ended up aligned. IDs
    // change the iteration order of the sets involved, so several are tried.
    for offset in 0..<40 {
        let first = WindowID(offset * 2 + 10)
        let second = first + 1
        let fake = FakeWindows()
        fake.add(first, aFrame)
        fake.add(second, bFrame, step: 17)
        fake.commandDrag(second, toX: 580, y: 300)
        fake.settle()
        #expect(fake.frame(first).height == fake.frame(second).height, "ids \(first), \(second)")
    }
}

@Test func dividerGivesWayToAMinimumSize() {
    let fake = FakeWindows()
    fake.add(a, aFrame)
    fake.add(b, bFrame, minWidth: 300)
    fake.commandDrag(b, toX: 580, y: 300)
    fake.settle()
    let surface = fake.liveSurfaces[0]
    let total = fake.frame(a).width + fake.frame(b).width
    surface.drag(surface.dividers[0], by: 400)
    fake.settle()
    #expect(fake.frame(b).width == 300)
    #expect(fake.frame(a).width + fake.frame(b).width == total)
}

@Test func closingAWindowInAPairLeavesThePartnerAlone() {
    let fake = joined()
    fake.close(b)
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
    #expect(fake.frame(a) == aFrame)
}

@Test func bringingOneWindowForwardRaisesTheCluster() {
    let fake = joined()
    fake.add(c, Rect(x: 600, y: 150, width: 500, height: 300))
    fake.manager.poll()
    fake.press(a)
    fake.release()
    fake.settle()
    #expect(Array(fake.order.prefix(2)) == [a, b])
}

@Test func raisingLeavesMinimizedWindowsDown() {
    let fake = joined()
    fake.add(c, Rect(x: 600, y: 150, width: 500, height: 300))
    fake.manager.poll()
    fake.windows[b]!.isMinimized = true
    let raises = fake.raises
    fake.press(a)
    fake.release()
    fake.settle()
    #expect(fake.order[0] == a)
    #expect(fake.raises == raises)
}

@Test func aClusterAlreadyInFrontIsNotRaisedAgain() {
    let fake = joined()
    fake.manager.poll()
    let raises = fake.raises
    fake.press(a)
    fake.release()
    fake.settle()
    fake.press(b)
    fake.release()
    fake.settle()
    #expect(fake.raises == raises)
}

@Test func clustersMoveIndependently() {
    let fake = joined()
    let d: WindowID = 4
    fake.add(c, Rect(x: 100, y: 700, width: 300, height: 200))
    fake.add(d, Rect(x: 900, y: 800, width: 300, height: 200))
    fake.commandDrag(d, toX: 380, y: 800)
    fake.settle()
    #expect(fake.manager.controllers.count == 2)
    let before = fake.frame(a)
    fake.press(c)
    fake.move(toX: 300, y: 650)
    fake.release()
    fake.settle()
    #expect(fake.frame(a) == before)
}

private func spreadOut(_ id: WindowID, _ frame: Rect) -> Rect {
    Rect(x: frame.x + Double(id) * 90, y: frame.y - Double(id) * 40, width: frame.width * 0.6, height: frame.height * 0.6)
}

@Test func windowsRearrangedTogetherAreNotFollowed() {
    let fake = joined()
    let before = (fake.frame(a), fake.frame(b))
    fake.overview = spreadOut
    fake.settle()
    fake.overview = nil
    fake.settle()
    #expect(fake.frame(a) == before.0)
    #expect(fake.frame(b) == before.1)
}

@Test func clickingDuringAnOverviewMovesNothing() {
    let fake = joined()
    let before = (fake.frame(a), fake.frame(b))
    fake.manager.suspend()
    fake.overview = spreadOut
    fake.manager.mouseDown()
    fake.manager.poll()
    fake.manager.mouseUp()
    fake.settle()
    fake.overview = nil
    fake.manager.resume()
    fake.settle()
    #expect(fake.frame(a) == before.0)
    #expect(fake.frame(b) == before.1)
}

@Test func suspendingCancelsAJoinInProgress() {
    let fake = twoWindows()
    fake.commandHeld = true
    fake.press(b)
    fake.move(toX: 580, y: 300)
    fake.manager.suspend()
    #expect(fake.preview == nil)
    fake.release()
    fake.commandHeld = false
    fake.manager.resume()
    fake.settle()
    #expect(fake.manager.controllers.isEmpty)
}
