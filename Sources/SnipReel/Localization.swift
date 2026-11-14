import Foundation

/// ローカライズ文字列(キーは英語。日本語は Resources/ja.lproj/Localizable.strings)
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 書式付き(%@ / %ld)
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
