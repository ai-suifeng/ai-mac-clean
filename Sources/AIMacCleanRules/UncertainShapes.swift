import Foundation

/// 「不确定」形态：PRD §5.1 明确点名、**无法安全分类**的数据。
///
/// 不确定类别默认锁定、只展示大小（PRD §8.3）。规则可以把它声明得更弱吗？不能：
/// 把它从「不确定」降级成「可归档会话」，等于让引擎去删一份它根本没读懂的数据。
/// 准入因此对这份清单做同样的包含判定：规则的模式整片落在某个不确定形态里、
/// 又声明成可归档 → 拒绝整条规则并给出可读原因。
///
/// 清单只收 PRD §5.1 点名的形态；文档没点名的数据一律留作「不确定」默认，
/// 而不是猜一个更弱的类别——保守方向（spec #7「PRD 未覆盖时选择更保守的方案」）。
enum UncertainShapes {

    /// 一个不确定形态。
    struct Shape {
        /// 形态标识，出错与测试里可读，例如 `uncertain/sqlite`。
        let identifier: String
        /// 相对工具根的路径模式（文件型：与相对路径的最后一段比较）。
        let pattern: PathPattern

        init(identifier: String, pattern: PathPattern) {
            self.identifier = identifier
            self.pattern = pattern
        }
    }

    /// 编译进二进制的形态清单。
    static let shapes: [Shape] = [
        Shape(identifier: "uncertain/sqlite", pattern: try! PathPattern("*.sqlite*")),
        Shape(identifier: "uncertain/protobuf", pattern: try! PathPattern("*.pb")),
        Shape(identifier: "uncertain/indexeddb", pattern: try! PathPattern("IndexedDB*")),
        Shape(identifier: "uncertain/leveldb", pattern: try! PathPattern("leveldb*")),
        Shape(identifier: "uncertain/blob", pattern: try! PathPattern("*.blob*")),
    ]

    /// 某个路径模式是否整片落在某个不确定形态之内。
    ///
    /// 判定的方向与保护单调性一致：**整片**落进去才算「这条规则讲的就是这类数据」。
    /// 宽泛的写法（`**`、`*.json`）只是写得粗糙，不构成把「不确定」降级——
    /// 它们同样覆盖不了「可安全归档」的语义，兜底仍在代码层（PRD §8.3）。
    static func shape(containing pattern: PathPattern) -> Shape? {
        let declared = pattern.segments.map(SegmentLanguage.init(segment:))

        return shapes.first { shape in
            guard let last = declared.last else { return false }
            let shapeSegments = shape.pattern.segments.map(SegmentLanguage.init(segment:))
            guard let name = shapeSegments.last else { return false }
            return SegmentRelation.isContained(last, in: name)
        }
    }
}
