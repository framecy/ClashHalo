import SwiftUI
import AppKit

struct NSConnTable: NSViewRepresentable {
    @EnvironmentObject var M: AppModel
    let items: [Conn]
    @Binding var selection: Conn.ID?
    var onDisconnect: ((String) -> Void)?
    var onRuleEdit: ((Conn) -> Void)?
    
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NSConnTable
        
        init(_ parent: NSConnTable) {
            self.parent = parent
        }
        
        func numberOfRows(in tableView: NSTableView) -> Int {
            return parent.items.count
        }
        
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.items.count else { return nil }
            let item = parent.items[row]
            let identifier = tableColumn?.identifier.rawValue ?? ""
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(identifier)
            var view = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSHostingView<AnyView>
            
            let swiftUIView: AnyView
            
            switch identifier {
            case "host":
                swiftUIView = AnyView(
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.host).font(.dsBodyMedium).lineLimit(1)
                        Text("\(item.dstIP):\(item.port)").font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                )
            case "process":
                swiftUIView = AnyView(Text(item.process).font(.dsBody).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            case "network":
                swiftUIView = AnyView(Text(item.network).font(.dsMono).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            case "rule":
                swiftUIView = AnyView(Text(item.rule).font(.dsMono).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            case "chain":
                swiftUIView = AnyView(
                    HStack(spacing: 4) {
                        Text(item.chain).font(.dsBodySemibold).foregroundColor(item.category == "proxy" ? parent.M.accent : .secondary).lineLimit(1)
                        Text(item.node).font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                )
            case "down":
                swiftUIView = AnyView(Text(fmtRate(Double(item.downRate))).font(.dsMono).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            case "up":
                swiftUIView = AnyView(Text(fmtRate(Double(item.upRate))).font(.dsMono).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            case "total":
                swiftUIView = AnyView(Text(fmtBytes(Double(item.up + item.down))).font(.dsMono).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
            default:
                swiftUIView = AnyView(EmptyView())
            }
            
            if view == nil {
                view = NSHostingView(rootView: swiftUIView)
                view?.identifier = cellIdentifier
            } else {
                view?.rootView = swiftUIView
            }
            
            return view
        }
        
        func tableViewSelectionDidChange(_ notification: Notification) {
            let tableView = notification.object as! NSTableView
            let row = tableView.selectedRow
            if row >= 0 && row < parent.items.count {
                parent.selection = parent.items[row].id
            } else {
                parent.selection = nil
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        
        let tableView = NSTableView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.headerView = NSTableHeaderView()
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 36
        
        let columns = [
            ("主机", "host", 240.0),
            ("进程", "process", 120.0),
            ("网络", "network", 60.0),
            ("规则", "rule", 150.0),
            ("链路", "chain", 180.0),
            ("↓", "down", 80.0),
            ("↑", "up", 80.0),
            ("总量", "total", 100.0)
        ]
        
        for (title, id, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            tableView.addTableColumn(col)
        }
        
        scrollView.documentView = tableView
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tableView = nsView.documentView as? NSTableView {
            context.coordinator.parent = self
            tableView.reloadData()
            
            // Sync selection back to table
            if let sel = selection {
                if let idx = items.firstIndex(where: { $0.id == sel }) {
                    if tableView.selectedRow != idx {
                        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    }
                }
            } else {
                tableView.deselectAll(nil)
            }
        }
    }
}
