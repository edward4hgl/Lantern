import Foundation

/// 「宝宝 2岁3个月」这种字句的计算。
///
/// 用户写一个模板，`{name}` 是称呼、`{age}` 是按「拍摄日期 − 生日」算出的年龄，
/// 默认 `{name} {age}`。拍摄早于生日（时间线倒放 / 还没出生）返回 nil —— 宁可什么都不显示。
enum AgeLabel {

    static let nameToken = "{name}"
    static let ageToken = "{age}"
    static let defaultTemplate = "{name} {age}"

    /// 只有年龄本身，例如「2岁3个月」「8个月」「12天」——
    /// 粒度刻意不规则，这正是家长嘴上会说的说法。
    static func ageText(birthday: Date, at date: Date, calendar: Calendar = .current) -> String? {
        guard date >= birthday else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: birthday, to: date)
        let years = parts.year ?? 0
        let months = parts.month ?? 0
        let days = parts.day ?? 0

        if years > 0 {
            return months > 0 ? "\(years)岁\(months)个月" : "\(years)岁"
        }
        if months > 0 {
            return "\(months)个月"
        }
        return "\(days)天"
    }

    /// 套模板。生日或拍摄日期缺失、或拍摄早于生日，返回 nil。
    static func text(birthday: Date?, at date: Date?, name: String, template: String) -> String? {
        guard let birthday, let date else { return nil }
        guard let age = ageText(birthday: birthday, at: date) else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = template.trimmingCharacters(in: .whitespacesAndNewlines)
        // 模板里一个占位符都没有 = 用户只想看固定文字，照原样显示
        var out = body.isEmpty ? defaultTemplate : body
        out = out.replacingOccurrences(of: ageToken, with: age)
        out = out.replacingOccurrences(of: nameToken, with: trimmedName)

        let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
