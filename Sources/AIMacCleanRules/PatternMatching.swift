import Foundation

/// 路径模式对**具体相对路径**的匹配。
///
/// 准入的包含关系判定（`SegmentRelation`）回答的是「两个模式之间是什么关系」；
/// 这里回答的是「这条具体路径有没有被这条模式覆盖」，供准入结果提供类别查询。
/// 完整的匹配语义（结构指纹、命中信号等）属于发现器（issue #12）。
enum PatternMatching {

    /// `relativePath`（相对工具根、以 `/` 分隔）是否被 `pattern` 覆盖。
    static func matches(_ pattern: PathPattern, relativePath: String) -> Bool {
        let segments = ProtectedPathMath.components(of: relativePath)
        let languages = pattern.segments.map(SegmentLanguage.init(segment:))
        return matches(languages, segments)
    }

    private static func matches(_ languages: [SegmentLanguage], _ segments: [String]) -> Bool {
        var patternIndex = 0
        var segmentIndex = 0

        while patternIndex < languages.count {
            let language = languages[patternIndex]

            // `**` 吃掉剩余的**全部**分段，且至少一段。
            if language.isRecursiveWildcard {
                return segmentIndex < segments.count
            }

            guard segmentIndex < segments.count,
                  SegmentRelation.matches(language, text: segments[segmentIndex])
            else { return false }

            patternIndex += 1
            segmentIndex += 1
        }

        return segmentIndex == segments.count
    }
}
