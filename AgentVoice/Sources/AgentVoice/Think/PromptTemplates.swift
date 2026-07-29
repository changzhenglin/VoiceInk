import Foundation

/// Prompt 模板组装（纯函数，scene+knowledge→prompt）
/// 模板规则表是 single source（spec §2.2），未来 C 版照此实现。
public enum PromptTemplates {

    /// 按 SceneType 选模板 + 注入 KnowledgeContext
    public static func build(raw: String, scene: SceneContext,
                             knowledge: KnowledgeContext) -> String {
        let template: String
        let injectConventions: Bool

        switch scene.sceneType {
        case .coding:
            template = """
                你是编程语音输入助手。将以下口述内容转为清晰的技术表述/代码注释/commit message。\
                保留技术术语，去除口语冗余（嗯/那个/就是）。输出纯文本，不加 markdown 格式。
                """
            injectConventions = true
        case .officeWriting, .custom:
            template = """
                你是办公语音输入助手。将以下口述内容润色为书面语。\
                去除口语冗余，修正语法，保持原意。输出纯文本。
                """
            injectConventions = false
        }

        var parts = [template]

        // 知识注入（空 knowledge 不追加任何段）
        if !knowledge.terms.isEmpty {
            parts.append("项目术语：\(knowledge.terms.joined(separator: "、"))")
        }
        if injectConventions, let conventions = knowledge.conventions {
            parts.append("代码规范：\(conventions)")
        }

        parts.append("口述内容：\(raw)")

        return parts.joined(separator: "\n\n")
    }
}
