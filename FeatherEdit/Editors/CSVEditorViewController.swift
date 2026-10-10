import AppKit

final class CSVEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    
    // MARK: - Optimized CSV Document Model
    
    private struct CellSpan {
        let start: String.Index
        let end: String.Index
        let isQuoted: Bool
    }
    
    private var rawText: String = ""
    private var grid: [[CellSpan]] = []
    private var edits: [Int: [Int: String]] = [:]
    private var maxCols: Int = 0
    
    var tableView: NSTableView!
    var scrollView: NSScrollView!
    var loadingIndicator: NSProgressIndicator!
    
    var onDocumentModified: (() -> Void)?
    var syncToText: ((String) -> Void)?
    
    override func loadView() {
        self.view = NSView()
        self.view.translatesAutoresizingMaskIntoConstraints = false
        
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        
        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 24
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.isDisplayedWhenStopped = false
        
        scrollView.documentView = tableView
        view.addSubview(scrollView)
        view.addSubview(loadingIndicator)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    // MARK: - Background Parsing
    
    func loadCSV(from text: String) {
        // Show spinner
        loadingIndicator.startAnimation(nil)
        tableView.isHidden = true
        
        // Parse off the main thread to prevent UI freezes on massive files
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let utf8 = text.utf8
            var currentGrid: [[CellSpan]] = []
            var currentRow: [CellSpan] = []
            var currentMaxCols = 0
            
            var currentIndex = utf8.startIndex
            let endIndex = utf8.endIndex
            var cellStart = currentIndex
            var inQuotes = false
            var isQuoted = false
            
            let quoteByte: UInt8 = 34 // "
            let commaByte: UInt8 = 44 // ,
            let lfByte: UInt8    = 10 // \n
            let crByte: UInt8    = 13 // \r
            
            while currentIndex < endIndex {
                let byte = utf8[currentIndex]
                
                if byte == quoteByte {
                    if inQuotes {
                        let nextIndex = utf8.index(after: currentIndex)
                        if nextIndex < endIndex && utf8[nextIndex] == quoteByte {
                            currentIndex = nextIndex // Skip escaped quote
                        } else {
                            inQuotes = false
                        }
                    } else {
                        inQuotes = true
                        isQuoted = true
                    }
                } else if byte == commaByte && !inQuotes {
                    currentRow.append(CellSpan(start: cellStart, end: currentIndex, isQuoted: isQuoted))
                    currentIndex = utf8.index(after: currentIndex)
                    cellStart = currentIndex
                    isQuoted = false
                    continue
                } else if (byte == lfByte || byte == crByte) && !inQuotes {
                    currentRow.append(CellSpan(start: cellStart, end: currentIndex, isQuoted: isQuoted))
                    currentGrid.append(currentRow)
                    if currentRow.count > currentMaxCols { currentMaxCols = currentRow.count }
                    currentRow = []
                    
                    let nextIndex = utf8.index(after: currentIndex)
                    if byte == crByte && nextIndex < endIndex && utf8[nextIndex] == lfByte {
                        currentIndex = nextIndex
                    }
                    currentIndex = utf8.index(after: currentIndex)
                    cellStart = currentIndex
                    isQuoted = false
                    continue
                }
                
                currentIndex = utf8.index(after: currentIndex)
            }
            
            if cellStart <= endIndex {
                currentRow.append(CellSpan(start: cellStart, end: endIndex, isQuoted: isQuoted))
            }
            if !currentRow.isEmpty {
                currentGrid.append(currentRow)
                if currentRow.count > currentMaxCols { currentMaxCols = currentRow.count }
            }
            
            DispatchQueue.main.async {
                self.rawText = text
                self.grid = currentGrid
                self.maxCols = currentMaxCols
                self.edits = [:]
                self.updateTableColumns()
                self.tableView.reloadData()
                
                self.loadingIndicator.stopAnimation(nil)
                self.tableView.isHidden = false
            }
        }
    }
    
    private func updateTableColumns() {
        for col in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(col)
        }
        for i in 0..<maxCols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "\(i)"))
            col.title = "Col \(i + 1)"
            col.width = 120
            tableView.addTableColumn(col)
        }
    }
    
    private func cellText(atRow row: Int, col: Int) -> String {
        if let edited = edits[row]?[col] { return edited }
        guard row < grid.count, col < grid[row].count else { return "" }
        let span = grid[row][col]
        var content = String(rawText[span.start..<span.end])
        if span.isQuoted {
            if content.hasPrefix("\"") { content.removeFirst() }
            if content.hasSuffix("\"") { content.removeLast() }
            content = content.replacingOccurrences(of: "\"\"", with: "\"")
        }
        return content
    }
    
    func saveCSV() -> String? {
        if edits.isEmpty { return rawText }
        
        var output = ""
        output.reserveCapacity(rawText.utf8.count + 1024)
        
        for rowIdx in 0..<grid.count {
            let rowColsCount = max(grid[rowIdx].count, edits[rowIdx]?.keys.max().map { $0 + 1 } ?? 0)
            
            for colIdx in 0..<rowColsCount {
                var content = cellText(atRow: rowIdx, col: colIdx)
                if content.contains(",") || content.contains("\"") || content.contains("\n") {
                    content = "\"" + content.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                output += content
                if colIdx < rowColsCount - 1 {
                    output += ","
                }
            }
            if rowIdx < grid.count - 1 {
                output += "\n"
            }
        }
        
        // After save, the rawText is effectively updated. 
        // For purity, we shouldn't overwrite rawText until loadCSV is called again, 
        // but returning the built string handles the sync.
        return output
    }
    
    // MARK: - NSTableViewDataSource & Delegate
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return grid.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colIdentifier = tableColumn?.identifier.rawValue,
              let colIndex = Int(colIdentifier) else { return nil }
        
        let cellIdentifier = NSUserInterfaceItemIdentifier("Cell")
        var textField = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField
        
        if textField == nil {
            textField = NSTextField()
            textField?.identifier = cellIdentifier
            textField?.isBordered = false
            textField?.drawsBackground = false
            textField?.delegate = self
            textField?.target = self
            textField?.action = #selector(cellEdited(_:))
            textField?.cell?.truncatesLastVisibleLine = true
        }
        
        textField?.stringValue = cellText(atRow: row, col: colIndex)
        textField?.tag = (row << 16) + colIndex
        
        return textField
    }
    
    @objc func cellEdited(_ sender: NSTextField) {
        let row = sender.tag >> 16
        let col = sender.tag & 0xFFFF
        
        if edits[row] == nil {
            edits[row] = [:]
        }
        edits[row]?[col] = sender.stringValue
        
        onDocumentModified?()
        if let text = saveCSV() {
            syncToText?(text)
        }
    }
    
    func controlTextDidEndEditing(_ obj: Notification) {
        if let textField = obj.object as? NSTextField {
            cellEdited(textField)
        }
    }
}
