import Foundation

public extension JSONValue {
    init(any value: Any?) {
        switch value {
        case nil:
            self = .null
        case let json as JSONValue:
            self = json
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let s):
            return s
        case .number(let n):
            if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
                return Int(n)
            }
            return n
        case .bool(let b):
            return b
        case .null:
            return NSNull()
        case .array(let a):
            return a.map(\.anyValue)
        case .object(let o):
            return o.mapValues(\.anyValue)
        }
    }
}
