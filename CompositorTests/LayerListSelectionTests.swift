import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerListSelectionTests {
    private final class Table: NSTableView {
        var revealedRows: [Int] = []
        override func scrollRowToVisible(_ row: Int) {
            revealedRows.append(row)
            super.scrollRowToVisible(row)
        }
    }

    private func makeList() -> (EditorSession, NativeLayerList.Coordinator, Table, [UUID]) {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        for _ in 0..<20 { session.addBlankLayer() }
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = Table()
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 52
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.update(table)
        table.revealedRows = []
        return (session, coordinator, table, session.layerRows.map(\.layer.id))
    }

    @Test func selectingAnOffscreenLayerRevealsItsRow() throws {
        let (session, coordinator, table, ids) = makeList()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 260, height: 160))
        scroll.documentView = table
        table.frame = CGRect(x: 0, y: 0, width: 260, height: 1040)
        scroll.layoutSubtreeIfNeeded()
        #expect(!table.visibleRect.intersects(table.rect(ofRow: 19)))
        session.selectLayer(ids[19])
        coordinator.update(table)
        #expect(table.selectedRowIndexes == IndexSet(integer: 19))
        #expect(table.revealedRows == [19])
        #expect(table.visibleRect.intersects(table.rect(ofRow: 19)))
    }

    @Test func refreshingTheSameSelectionDoesNotScrollAgain() {
        let (session, coordinator, table, ids) = makeList()
        session.selectLayer(ids[19])
        coordinator.update(table)
        table.revealedRows = []
        session.document?.layers[0].name = "Renamed"
        coordinator.update(table)
        #expect(table.revealedRows.isEmpty)
        session.selectLayer(nil)
        coordinator.update(table)
        #expect(table.revealedRows.isEmpty)
        session.selectLayer(ids[19])
        coordinator.update(table)
        #expect(table.revealedRows == [19])
    }

    @Test func changingPrimaryLayerWithinTheSameSelectionRevealsIt() {
        let (session, coordinator, table, ids) = makeList()
        let selected: Set<UUID> = [ids[0], ids[19]]
        session.selectLayers(selected, primary: ids[19])
        coordinator.update(table)
        #expect(table.revealedRows == [19])
        table.revealedRows = []
        session.selectLayers(selected, primary: ids[0])
        coordinator.update(table)
        #expect(table.selectedRowIndexes == IndexSet([0, 19]))
        #expect(table.revealedRows == [0])
    }

    @Test func selectingAChildExpandsOnlyItsAncestorFolders() throws {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        session.addGroup()
        let outer = try #require(session.activeLayerID)
        session.addGroup()
        let inner = try #require(session.activeLayerID)
        session.addBlankLayer()
        let child = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.addGroup()
        let unrelated = try #require(session.activeLayerID)
        session.collapsedGroupIDs = [outer, inner, unrelated]
        session.selectLayer(child)
        #expect(session.collapsedGroupIDs == [unrelated])
        #expect(session.layerRows.contains { $0.layer.id == child })
        session.selectLayer(unrelated)
        #expect(session.collapsedGroupIDs == [unrelated])
    }

    @Test func multipleSelectionRevealsThePrimaryChild() throws {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.addBlankLayer()
        let child = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.addBlankLayer()
        let other = try #require(session.activeLayerID)
        session.collapsedGroupIDs = [folder]
        session.selectLayers([child, other], primary: child)
        #expect(session.collapsedGroupIDs.isEmpty)
        #expect(session.selectedLayerIDs == [child, other])
    }
}
