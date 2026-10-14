import Foundation

extension KeyedDecodingContainer {
    /// 读一个路径模式字段，并把模式语法错误原样抛给调用方。
    func decodePattern(forKey key: Key) throws -> PathPattern {
        do {
            return try decode(PathPattern.self, forKey: key)
        } catch let error as RuleFormatError {
            // 规则文件里的模式字段写错了，报错时要指明是哪个字段。
            throw RuleFormatError.invalidFieldValue(field: key.stringValue, reason: error.errorDescription ?? "\(error)")
        }
    }

    /// 读一组路径模式字段；缺省为空数组。
    func decodePatterns(forKey key: Key) throws -> [PathPattern] {
        do {
            return try decodeIfPresent([PathPattern].self, forKey: key) ?? []
        } catch let error as RuleFormatError {
            throw RuleFormatError.invalidFieldValue(field: key.stringValue, reason: error.errorDescription ?? "\(error)")
        }
    }
}
