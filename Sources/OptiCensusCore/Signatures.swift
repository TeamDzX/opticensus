import Foundation

/// What counts as AI. Data, not code: a `signatures.json` in the store folder
/// replaces the built-in list, so it can be updated without a new build.
public struct Signatures: Codable {
    public struct Tool: Codable {
        public var id: String
        public var name: String
        public var bundleIds: [String]?
        public var bundlePrefixes: [String]?
        public var appNames: [String]?       // lower case, without ".app"
        public var processes: [String]?      // executable names, lower case
        public var commands: [String]?       // names looked for on the PATH
        public var keywords: [String]?       // found in an autostart label or command
        public var argKeywords: [String]?    // found in a running command line
    }

    public struct Port: Codable {
        public var port: Int
        public var name: String
    }

    public struct Extension: Codable {
        public var id: String
        public var name: String
    }

    public var version: String
    public var tools: [Tool]
    public var ports: [Port]
    public var keyNames: [String]
    public var keyPrefixes: [String]
    public var extensions: [Extension]
    public var extensionKeywords: [String]

    public static let builtIn: Signatures = {
        // A broken built-in list is a programming error, caught by the tests.
        try! JSONDecoder().decode(Signatures.self, from: Data(builtInJSON.utf8))
    }()

    public static func load(storeDir: URL) -> Signatures {
        let f = storeDir.appendingPathComponent("signatures.json")
        if let d = try? Data(contentsOf: f), let s = try? JSONDecoder().decode(Signatures.self, from: d) {
            return s
        }
        return builtIn
    }

    // MARK: matching

    func tool(bundleId: String, appName: String) -> Tool? {
        let bid = bundleId.lowercased(), app = appName.lowercased()
        return tools.first { t in
            (t.bundleIds ?? []).contains { $0.lowercased() == bid }
                || (!bid.isEmpty && (t.bundlePrefixes ?? []).contains { bid.hasPrefix($0.lowercased()) })
                || (t.appNames ?? []).contains(app)
        }
    }

    func tool(process name: String) -> Tool? {
        let n = name.lowercased()
        return tools.first { ($0.processes ?? []).contains(n) }
    }

    func tool(keywordIn haystack: String) -> Tool? {
        let h = haystack.lowercased()
        return tools.first { ($0.keywords ?? []).contains { h.contains($0) } }
    }

    func tool(argKeywordIn haystack: String) -> Tool? {
        let h = haystack.lowercased()
        return tools.first { ($0.argKeywords ?? []).contains { h.contains($0) } }
    }

    func isKeyName(_ name: String) -> Bool {
        keyNames.contains(name) || keyPrefixes.contains { name.hasPrefix($0) }
    }

    func isAIExtension(id: String, name: String) -> Bool {
        if extensions.contains(where: { $0.id == id }) { return true }
        let lower = name.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return extensionKeywords.contains { $0.contains(" ") ? lower.contains($0) : words.contains($0) }
    }
}

// First draft, written from memory on 24 Nov 2026 and not checked against
// installed copies of each product. Apps are matched by name as well as by
// bundle id for that reason. The Claude browser extension id was confirmed
// against an installed copy in Edge.
let builtInJSON = #"""
{
  "version": "2026-11-24",
  "tools": [
    {"id": "claude", "name": "Claude",
     "bundleIds": ["com.anthropic.claudefordesktop"], "bundlePrefixes": ["com.anthropic."],
     "appNames": ["claude"], "processes": ["claude"], "commands": ["claude"], "keywords": ["claude"]},
    {"id": "chatgpt", "name": "ChatGPT",
     "bundleIds": ["com.openai.chat", "com.openai.atlas"], "bundlePrefixes": ["com.openai."],
     "appNames": ["chatgpt", "chatgpt atlas"], "processes": ["chatgpt"], "keywords": ["chatgpt", "openai"]},
    {"id": "codex", "name": "Codex", "processes": ["codex"], "commands": ["codex"], "keywords": ["codex"]},
    {"id": "gemini", "name": "Gemini", "appNames": ["gemini"], "processes": ["gemini"],
     "commands": ["gemini"], "keywords": ["gemini"]},
    {"id": "cursor", "name": "Cursor", "bundleIds": ["com.todesktop.230313mzl4w4u92"],
     "appNames": ["cursor"], "processes": ["cursor"], "commands": ["cursor-agent"], "keywords": ["cursor-agent"]},
    {"id": "windsurf", "name": "Windsurf", "bundleIds": ["com.exafunction.windsurf"],
     "appNames": ["windsurf"], "processes": ["windsurf"], "keywords": ["windsurf"]},
    {"id": "copilot", "name": "Copilot", "appNames": ["copilot"], "processes": ["copilot"],
     "commands": ["copilot"], "keywords": ["copilot"]},
    {"id": "ollama", "name": "Ollama", "bundleIds": ["com.electron.ollama"],
     "appNames": ["ollama"], "processes": ["ollama"], "commands": ["ollama"], "keywords": ["ollama"]},
    {"id": "lmstudio", "name": "LM Studio", "bundleIds": ["ai.elementlabs.lmstudio"],
     "appNames": ["lm studio"], "processes": ["lm studio", "lms"], "commands": ["lms"],
     "keywords": ["lmstudio", "lm studio"]},
    {"id": "llamacpp", "name": "llama.cpp", "processes": ["llama-server", "llama-cli"],
     "commands": ["llama-server", "llama-cli"], "keywords": ["llama-server", "llama.cpp", "llama_cpp"],
     "argKeywords": ["llama_cpp"]},
    {"id": "mlx", "name": "MLX LM", "commands": ["mlx_lm.server", "mlx_lm.generate"],
     "keywords": ["mlx_lm"], "argKeywords": ["mlx_lm"]},
    {"id": "comfyui", "name": "ComfyUI", "appNames": ["comfyui"], "processes": ["comfyui"],
     "keywords": ["comfyui"], "argKeywords": ["comfyui"]},
    {"id": "openwebui", "name": "Open WebUI", "commands": ["open-webui"],
     "keywords": ["open-webui", "openwebui"], "argKeywords": ["open-webui", "open_webui"]},
    {"id": "jan", "name": "Jan", "bundleIds": ["jan.ai.app"], "appNames": ["jan"], "processes": ["jan"]},
    {"id": "gpt4all", "name": "GPT4All", "appNames": ["gpt4all"], "processes": ["gpt4all"], "keywords": ["gpt4all"]},
    {"id": "msty", "name": "Msty", "appNames": ["msty"], "processes": ["msty"]},
    {"id": "perplexity", "name": "Perplexity", "bundlePrefixes": ["ai.perplexity."],
     "appNames": ["perplexity", "comet"], "processes": ["perplexity", "comet"], "keywords": ["perplexity"]},
    {"id": "aider", "name": "Aider", "processes": ["aider"], "commands": ["aider"]},
    {"id": "opencode", "name": "opencode", "processes": ["opencode"], "commands": ["opencode"], "keywords": ["opencode"]},
    {"id": "goose", "name": "Goose", "appNames": ["goose"], "commands": ["goose"]},
    {"id": "llm", "name": "llm", "commands": ["llm"]},
    {"id": "whisper", "name": "Whisper",
     "bundleIds": ["com.goodsnooze.MacWhisper", "com.superduper.superwhisper"],
     "appNames": ["macwhisper", "superwhisper"], "commands": ["whisper"]},
    {"id": "diffusion", "name": "Image generation",
     "bundleIds": ["com.diffusionbee.diffusionbee", "com.liuliu.draw-things"],
     "appNames": ["diffusionbee", "draw things"]},
    {"id": "myllm", "name": "MyLLM", "appNames": ["myllm"], "processes": ["myllm"], "keywords": ["myllm"]}
  ],
  "ports": [
    {"port": 11434, "name": "Ollama-style model server"},
    {"port": 11435, "name": "Ollama-style proxy"},
    {"port": 8188, "name": "ComfyUI-style image server"},
    {"port": 1234, "name": "LM Studio-style model server"},
    {"port": 1337, "name": "Jan-style model server"},
    {"port": 4891, "name": "GPT4All-style model server"},
    {"port": 5001, "name": "KoboldCpp-style model server"},
    {"port": 7860, "name": "Gradio-style web UI"}
  ],
  "keyNames": ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "GOOGLE_AI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
  "keyPrefixes": ["AI_", "ANTHROPIC_", "CLAUDE_", "OPENAI_", "AZURE_OPENAI_", "GEMINI_", "MISTRAL_", "GROQ_",
                  "OPENROUTER_", "DEEPSEEK_", "XAI_", "COHERE_", "PERPLEXITY_", "REPLICATE_", "TOGETHER_",
                  "FIREWORKS_", "HUGGINGFACE_", "OLLAMA_", "LITELLM_", "ELEVENLABS_"],
  "extensions": [
    {"id": "fcoeoabgfenejglbffodgkkbkcdhcgfn", "name": "Claude in Chrome"}
  ],
  "extensionKeywords": ["ai", "gpt", "chatgpt", "claude", "copilot", "gemini", "perplexity", "openai",
                        "deepseek", "llm", "grammarly", "monica", "sider", "merlin", "maxai", "harpa"]
}
"""#
