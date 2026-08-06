import Combine
import Foundation

extension Notification.Name {
    static let devTypeLanguageChanged = Notification.Name("devtype.language.changed")
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ko
    case ja

    public var id: String { rawValue }

    public var endonym: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }
}

/// In-code string tables for SPM executable (no Bundle.module .lproj dependency).
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    public static let deviceKey = "devtype.device.uiLanguage"

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.deviceKey)
            NotificationCenter.default.post(name: .devTypeLanguageChanged, object: nil)
        }
    }

    private let tables: [AppLanguage: [String: String]]

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.deviceKey)
        language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        tables = Self.buildTables()
    }

    public func s(_ key: String, _ args: CVarArg...) -> String {
        let code = effectiveLanguageCode()
        let lang = AppLanguage(rawValue: code) ?? .en
        let format = tables[lang]?[key] ?? tables[.en]?[key] ?? key
        if args.isEmpty { return format }
        return String(format: format, arguments: args)
    }

    private func effectiveLanguageCode() -> String {
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("ko") { return "ko" }
            if preferred.hasPrefix("ja") { return "ja" }
            return "en"
        case .en, .ko, .ja:
            return language.rawValue
        }
    }

    private static func buildTables() -> [AppLanguage: [String: String]] {
        let en: [String: String] = [
            "common.cancel": "Cancel",
            "common.clear": "Clear",
            "fillin.title": "Fill In Fields",
            "fillin.subtitle": "Complete the fields below, then insert.",
            "fillin.insert": "Insert",
            "fillin.include": "Include %@",
            "search.placeholder": "Search snippets…",
            "search.hint.navigate": "Navigate",
            "search.hint.expand": "Expand",
            "search.hint.jump": "Jump",
            "search.hint.close": "Close",
            "search.count": "%d of %d",
            "search.empty.title": "No matching snippets",
            "search.empty.subtitle": "Try a different search, or add a snippet in the manager.",
            "snippets.empty.noMatch": "No snippets match “%@”",
            "menu.manage": "Manage Snippets…",
            "menu.import": "Import Snippets…",
            "menu.inlineSearch": "Inline Search",
            "menu.recent": "Recent Expansions",
            "menu.recent.empty": "No Recent Expansions",
            "menu.openAtLogin": "Open at Login",
            "menu.language": "Language",
            "menu.recovery": "Permission Recovery…",
            "menu.diagnoseSecure": "Diagnose Secure Input",
            "menu.mute.front": "Mute Frontmost App",
            "menu.mute.apps": "Muted Apps…",
            "menu.quit": "Quit DevType",
            "menu.textExpanderWarning": "TextExpander is running — disable it to avoid conflicts.",
            "menu.espansoWarning": "Espanso is running — disable it to avoid conflicts.",
            "manager.title": "Snippets",
            "manager.subtitle": "Type less. Expand more.",
            "manager.filter": "Filter",
            "manager.import": "Import",
            "manager.group.all": "All Snippets",
            "manager.add": "New Snippet",
            "manager.edit": "Edit",
            "manager.delete": "Delete",
            "manager.reset": "Reset Defaults",
            "manager.stats": "%d active · %d total",
            "manager.delete.confirm.title": "Delete Snippet?",
            "manager.delete.confirm.message": "“%@” will be permanently removed.",
            "manager.group.add": "New Group",
            "manager.group.edit": "Edit Group…",
            "manager.group.enable": "Enable Group",
            "manager.group.disable": "Disable Group",
            "manager.group.delete": "Delete Group…",
            "manager.group.delete.title": "Delete Group?",
            "manager.group.delete.message": "“%@” contains %d snippet(s). Move them to another group, or delete everything.",
            "manager.group.delete.move": "Move Snippets",
            "manager.group.delete.last": "Keep at least one group in your library.",
            "manager.group.delete.all": "Delete All",
            "manager.duplicate": "Duplicate",
            "manager.moveToGroup": "Move to Group",
            "manager.empty.title": "No snippets yet",
            "manager.empty.subtitle": "Create your first expansion — pick a trigger, type the rest.",
            "editor.group": "Group",
            "editor.behavior": "Behavior",

            "editor.plainText": "Plain Text",
            "editor.macros": "Insert Macro",
            "editor.macro.date": "Date / Time",
            "editor.macro.cursor": "Cursor Position",
            "editor.macro.clipboard": "Clipboard",
            "editor.macro.filltext": "Fill-in: Single Line",
            "editor.macro.fillarea": "Fill-in: Multi-line",
            "editor.macro.fillpopup": "Fill-in: Popup",
            "editor.macro.fillpart": "Optional Section",
            "editor.macro.nested": "Nested Snippet",
            "editor.macro.keyEnter": "Key: Return",
            "editor.macro.keyTab": "Key: Tab",
            "editor.image.attach": "Image…",
            "editor.image.remove": "Remove",
            "editor.image.attached": "Image attached — expands as a pasted image",
            "editor.preview": "Preview",
            "editor.chars": "%d characters",
            "editor.fillins": "%d fill-ins",
            "groupeditor.add": "New Group",
            "groupeditor.edit": "Edit Group",
            "groupeditor.name": "Name",
            "groupeditor.icon": "Icon",
            "groupeditor.color": "Color",
            "groupeditor.enabled": "Enabled",
            "groupeditor.save": "Save Group",
            "groupeditor.error.emptyName": "Enter a name for this group.",
            "groupeditor.error.duplicate": "A group named “%@” already exists.",
            "editor.add": "New Snippet",
            "editor.edit": "Edit Snippet",
            "editor.name": "Title",
            "editor.trigger": "Trigger",
            "editor.replacement": "Replacement",
            "editor.enabled": "Enabled",
            "editor.caseSensitive": "Case Sensitive",
            "editor.wordBoundary": "Word Boundary",
            "editor.save": "Save Snippet",
            "editor.error.emptyTrigger": "Enter a trigger to save this snippet.",
            "editor.error.conflict": "“%@” conflicts with existing trigger “%@”.",
        ]
        let ko: [String: String] = [
            "common.cancel": "취소",
            "common.clear": "지우기",
            "fillin.title": "입력 필드",
            "fillin.subtitle": "아래 필드를 입력한 후 삽입하세요.",
            "fillin.insert": "삽입",
            "fillin.include": "%@ 포함",
            "search.placeholder": "스니펫 검색…",
            "search.hint.navigate": "이동",
            "search.hint.expand": "확장",
            "search.hint.jump": "바로가기",
            "search.hint.close": "닫기",
            "search.count": "%d / %d",
            "search.empty.title": "일치하는 스니펫 없음",
            "search.empty.subtitle": "다른 검색어를 입력하거나 관리자에서 스니펫을 추가하세요.",
            "snippets.empty.noMatch": "“%@”와 일치하는 스니펫이 없습니다",
            "menu.manage": "스니펫 관리…",
            "menu.import": "스니펫 가져오기…",
            "menu.inlineSearch": "인라인 검색",
            "menu.recent": "최근 확장",
            "menu.recent.empty": "최근 확장 없음",
            "menu.openAtLogin": "로그인 시 열기",
            "menu.language": "언어",
            "menu.recovery": "권한 복구…",
            "menu.diagnoseSecure": "보안 입력 진단",
            "menu.mute.front": "최상위 앱 음소거",
            "menu.mute.apps": "음소거된 앱…",
            "menu.quit": "DevType 종료",
            "menu.textExpanderWarning": "TextExpander가 실행 중입니다 — 충돌을 피하려면 비활성화하세요.",
            "menu.espansoWarning": "Espanso가 실행 중입니다 — 충돌을 피하려면 비활성화하세요.",
            "manager.title": "스니펫",
            "manager.subtitle": "적게 입력하고, 더 많이 확장하세요.",
            "manager.filter": "필터",
            "manager.import": "가져오기",
            "manager.group.all": "모든 스니펫",
            "manager.add": "새 스니펫",
            "manager.edit": "편집",
            "manager.delete": "삭제",
            "manager.reset": "기본값 재설정",
            "manager.stats": "%d개 활성 · 전체 %d개",
            "manager.delete.confirm.title": "스니펫을 삭제할까요?",
            "manager.delete.confirm.message": "“%@”이(가) 영구적으로 삭제됩니다.",
            "manager.group.add": "새 그룹",
            "manager.group.edit": "그룹 편집…",
            "manager.group.enable": "그룹 활성화",
            "manager.group.disable": "그룹 비활성화",
            "manager.group.delete": "그룹 삭제…",
            "manager.group.delete.title": "그룹을 삭제할까요?",
            "manager.group.delete.message": "“%@”에 스니펫 %d개가 있습니다. 다른 그룹으로 옮기거나 모두 삭제할 수 있습니다.",
            "manager.group.delete.move": "스니펫 이동",
            "manager.group.delete.last": "라이브러리에 그룹을 하나 이상 유지해야 합니다.",
            "manager.group.delete.all": "모두 삭제",
            "manager.duplicate": "복제",
            "manager.moveToGroup": "그룹으로 이동",
            "manager.empty.title": "스니펫이 없습니다",
            "manager.empty.subtitle": "첫 번째 확장을 만들어 보세요 — 트리거를 정하고 내용을 입력하면 됩니다.",
            "editor.group": "그룹",
            "editor.behavior": "동작",

            "editor.plainText": "일반 텍스트",
            "editor.macros": "매크로 삽입",
            "editor.macro.date": "날짜 / 시간",
            "editor.macro.cursor": "커서 위치",
            "editor.macro.clipboard": "클립보드",
            "editor.macro.filltext": "입력 필드: 한 줄",
            "editor.macro.fillarea": "입력 필드: 여러 줄",
            "editor.macro.fillpopup": "입력 필드: 팝업",
            "editor.macro.fillpart": "선택적 섹션",
            "editor.macro.nested": "중첩 스니펫",
            "editor.macro.keyEnter": "키: Return",
            "editor.macro.keyTab": "키: Tab",
            "editor.image.attach": "이미지…",
            "editor.image.remove": "제거",
            "editor.image.attached": "이미지 첨부됨 — 이미지로 붙여넣기 됩니다",
            "editor.preview": "미리보기",
            "editor.chars": "%d자",
            "editor.fillins": "입력 필드 %d개",
            "groupeditor.add": "새 그룹",
            "groupeditor.edit": "그룹 편집",
            "groupeditor.name": "이름",
            "groupeditor.icon": "아이콘",
            "groupeditor.color": "색상",
            "groupeditor.enabled": "활성화",
            "groupeditor.save": "그룹 저장",
            "groupeditor.error.emptyName": "그룹 이름을 입력하세요.",
            "groupeditor.error.duplicate": "“%@” 그룹이 이미 있습니다.",
            "editor.add": "새 스니펫",
            "editor.edit": "스니펫 편집",
            "editor.name": "제목",
            "editor.trigger": "트리거",
            "editor.replacement": "대체 텍스트",
            "editor.enabled": "활성화",
            "editor.caseSensitive": "대소문자 구분",
            "editor.wordBoundary": "단어 경계",
            "editor.save": "스니펫 저장",
            "editor.error.emptyTrigger": "저장하려면 트리거를 입력하세요.",
            "editor.error.conflict": "“%@”이(가) 기존 트리거 “%@”와(과) 충돌합니다.",
        ]
        let ja: [String: String] = [
            "common.cancel": "キャンセル",
            "common.clear": "クリア",
            "fillin.title": "入力フィールド",
            "fillin.subtitle": "以下のフィールドに入力して挿入してください。",
            "fillin.insert": "挿入",
            "fillin.include": "%@ を含める",
            "search.placeholder": "スニペットを検索…",
            "search.hint.navigate": "移動",
            "search.hint.expand": "展開",
            "search.hint.jump": "ジャンプ",
            "search.hint.close": "閉じる",
            "search.count": "%d / %d",
            "search.empty.title": "一致するスニペットなし",
            "search.empty.subtitle": "別の検索語を試すか、マネージャーでスニペットを追加してください。",
            "snippets.empty.noMatch": "「%@」に一致するスニペットがありません",
            "menu.manage": "スニペット管理…",
            "menu.import": "スニペットをインポート…",
            "menu.inlineSearch": "インライン検索",
            "menu.recent": "最近の展開",
            "menu.recent.empty": "最近の展開なし",
            "menu.openAtLogin": "ログイン時に開く",
            "menu.language": "言語",
            "menu.recovery": "権限の復旧…",
            "menu.diagnoseSecure": "セキュア入力を診断",
            "menu.mute.front": "最前面のアプリをミュート",
            "menu.mute.apps": "ミュート中のアプリ…",
            "menu.quit": "DevType を終了",
            "menu.textExpanderWarning": "TextExpander が実行中です — 競合を避けるには無効にしてください。",
            "menu.espansoWarning": "Espanso が実行中です — 競合を避けるには無効にしてください。",
            "manager.title": "スニペット",
            "manager.subtitle": "少ない入力で、より多くを展開。",
            "manager.filter": "フィルター",
            "manager.import": "インポート",
            "manager.group.all": "すべてのスニペット",
            "manager.add": "新規スニペット",
            "manager.edit": "編集",
            "manager.delete": "削除",
            "manager.reset": "デフォルトに戻す",
            "manager.stats": "%d 件有効 · 全 %d 件",
            "manager.delete.confirm.title": "スニペットを削除しますか？",
            "manager.delete.confirm.message": "「%@」は完全に削除されます。",
            "manager.group.add": "新規グループ",
            "manager.group.edit": "グループを編集…",
            "manager.group.enable": "グループを有効化",
            "manager.group.disable": "グループを無効化",
            "manager.group.delete": "グループを削除…",
            "manager.group.delete.title": "グループを削除しますか？",
            "manager.group.delete.message": "「%@」には %d 件のスニペットがあります。別のグループへ移動するか、すべて削除できます。",
            "manager.group.delete.move": "スニペットを移動",
            "manager.group.delete.last": "ライブラリには少なくとも 1 つのグループが必要です。",
            "manager.group.delete.all": "すべて削除",
            "manager.duplicate": "複製",
            "manager.moveToGroup": "グループへ移動",
            "manager.empty.title": "スニペットがありません",
            "manager.empty.subtitle": "最初の展開を作成しましょう — トリガーを決めて内容を入力するだけです。",
            "editor.group": "グループ",
            "editor.behavior": "動作",

            "editor.plainText": "プレーンテキスト",
            "editor.macros": "マクロを挿入",

            "editor.macro.date": "日付 / 時刻",
            "editor.macro.cursor": "カーソル位置",
            "editor.macro.clipboard": "クリップボード",
            "editor.macro.filltext": "入力: 単一行",
            "editor.macro.fillarea": "入力: 複数行",
            "editor.macro.fillpopup": "入力: ポップアップ",
            "editor.macro.fillpart": "オプションセクション",
            "editor.macro.nested": "ネストされたスニペット",
            "editor.macro.keyEnter": "キー: Return",
            "editor.macro.keyTab": "キー: Tab",
            "editor.image.attach": "画像…",
            "editor.image.remove": "削除",
            "editor.image.attached": "画像が添付されました — 画像として貼り付けます",
            "editor.preview": "プレビュー",
            "editor.chars": "%d 文字",
            "editor.fillins": "%d 件の入力フィールド",
            "groupeditor.add": "新規グループ",
            "groupeditor.edit": "グループを編集",
            "groupeditor.name": "名前",
            "groupeditor.icon": "アイコン",
            "groupeditor.color": "カラー",
            "groupeditor.enabled": "有効",
            "groupeditor.save": "グループを保存",
            "groupeditor.error.emptyName": "グループ名を入力してください。",
            "groupeditor.error.duplicate": "「%@」というグループは既に存在します。",
            "editor.add": "新規スニペット",
            "editor.edit": "スニペットを編集",
            "editor.name": "タイトル",
            "editor.trigger": "トリガー",
            "editor.replacement": "置換テキスト",
            "editor.enabled": "有効",
            "editor.caseSensitive": "大文字小文字を区別",
            "editor.wordBoundary": "単語境界",
            "editor.save": "スニペットを保存",
            "editor.error.emptyTrigger": "保存するにはトリガーを入力してください。",
            "editor.error.conflict": "「%@」は既存のトリガー「%@」と競合しています。",
        ]
        return [.en: en, .ko: ko, .ja: ja]
    }
}
