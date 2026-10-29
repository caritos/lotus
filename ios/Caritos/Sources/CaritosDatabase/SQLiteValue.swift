import Foundation

/// One SQLite value, used both for statement bindings and for decoded columns.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
