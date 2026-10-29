/// One result row, with its columns in the order the statement returned them.
public struct SQLiteRow: Sendable {
    let columns: [String]
    let values: [SQLiteValue]

    init(columns: [String], values: [SQLiteValue]) {
        precondition(columns.count == values.count, "SQLiteRow needs one value per column")
        self.columns = columns
        self.values = values
    }

    /// The value of the first column with this name, or nil when the row has no such column.
    public subscript(column: String) -> SQLiteValue? {
        guard let index = columns.firstIndex(of: column) else { return nil }
        return values[index]
    }

    /// The column's text, or nil when it is missing or not text.
    public func text(_ column: String) -> String? {
        if case .text(let value) = self[column] { return value }
        return nil
    }

    /// The column's integer, or nil when it is missing or not an integer.
    public func integer(_ column: String) -> Int64? {
        if case .integer(let value) = self[column] { return value }
        return nil
    }
}
