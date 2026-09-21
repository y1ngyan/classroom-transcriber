import Foundation

/// 一个课程预设：某一学科常用的一包术语。
///
/// 存在的理由：默认词表原来是**写死的一包机器学习术语**，词表机制本身是通的
/// （`GlossaryStore.contextualTerms` → `AnalyzerContext.contextualStrings`），
/// 但内容对不上课就完全不起作用。实测那条真实录音在聊 Claude、Kimi 这类
/// AI 工具，而词表里全是 gradient descent——一个都没命中。
///
/// 词表必须在**开录之前**就位，这是它和「事后校正」最根本的区别：
/// `contextualStrings` 是喂给识别器的先验，音频流一旦开始就改不了了。
/// 所以预设只能是**先验知识**（用户选、或从系统里带出来），
/// 不可能由本次课的内容推出来——那条路只能走事后提取，见 `extractTerms`。
///
/// `Codable` 是给用户自建的词库用的（`CoursePresetStore`）：
/// 内置的这 6 包是代码里的常量，不落盘；用户存下来的那些要写进 `presets.json`。
struct CoursePreset: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    /// 一句话说明这包词是干什么的，出现在菜单里
    let summary: String
    let entries: [GlossaryEntry]
}

/// 内置课程预设。
///
/// **aliases 大多数是空的，这是有意的。** `term` 才是喂给识别器的那一项
/// （见 `GlossaryStore.contextualTerms`），aliases 只影响事后那轮 LLM 校正。
/// 而 aliases 的语义是「实测误转写」——凭空编一批「可能被转错的样子」写进去，
/// 等于把自己的猜测伪装成实测结论，下一个读代码的人没法分辨哪些是真量到的。
///
/// 目前**唯一有实测支撑的 aliases 是 `Claude`**：在
/// 课堂-20260918-102756.wav 里被转成了 "cludelod Clod"。
/// 其余预设只给正确写法，让模型自己判断——UI 里也是这么写的
/// （「误转写留空也能用」）。
enum CoursePresets {

    /// 默认预设。首次启动种的就是它。
    static let `default`: CoursePreset = machineLearning

    static let all: [CoursePreset] = [
        machineLearning, aiTools, programming, mathematics, physics, economics,
    ]

    static func preset(id: String) -> CoursePreset? {
        all.first { $0.id == id }
    }

    // MARK: - 机器学习 / 深度学习

    static let machineLearning = CoursePreset(
        id: "machine-learning",
        name: "机器学习 / 深度学习",
        summary: "梯度下降、损失函数这类训练相关术语",
        entries: [
            GlossaryEntry(
                term: "machine learning",
                aliases: ["Machin learning", "machine lerning", "machin learning"],
                note: "机器学习"
            ),
            GlossaryEntry(
                term: "gradient descent",
                aliases: ["gredion destent", "gradient decent", "gradient desent"],
                note: "梯度下降"
            ),
            GlossaryEntry(
                term: "stochastic gradient descent",
                aliases: ["stochastic gradient decent", "stochastic gradient desent"],
                note: "随机梯度下降，缩写 SGD 也算正确写法"
            ),
            GlossaryEntry(
                term: "learning rate",
                aliases: ["learning reit", "lerning rate", "learning late"],
                note: "学习率，训练时的超参数"
            ),
            GlossaryEntry(
                term: "loss function",
                aliases: ["lost function", "loss funtion"],
                note: "损失函数"
            ),
            GlossaryEntry(
                term: "backpropagation",
                aliases: ["back propagation", "backpropogation", "back propagasion"],
                note: "反向传播"
            ),
            GlossaryEntry(
                term: "epoch",
                aliases: ["epok", "epochs"],
                note: "训练轮次；复数 epochs 视上下文可保留"
            ),
            GlossaryEntry(
                term: "MNIST",
                aliases: ["minist", "M NIST"],
                note: "手写数字数据集"
            ),
            GlossaryEntry(term: "neural network", note: "神经网络"),
            GlossaryEntry(term: "convolution", note: "卷积"),
            GlossaryEntry(term: "pooling", note: "池化"),
            GlossaryEntry(term: "activation function", note: "激活函数"),
            GlossaryEntry(term: "overfitting", note: "过拟合"),
            GlossaryEntry(term: "regularization", note: "正则化"),
            GlossaryEntry(term: "transformer", note: "注意力网络结构，注意与「变压器」区分"),
            GlossaryEntry(term: "attention", note: "注意力机制"),
            GlossaryEntry(term: "embedding", note: "嵌入向量"),
            GlossaryEntry(term: "batch normalization", note: "批归一化"),
            GlossaryEntry(term: "hyperparameter", note: "超参数"),
            GlossaryEntry(term: "validation set", note: "验证集"),
            GlossaryEntry(term: "confusion matrix", note: "混淆矩阵"),
            GlossaryEntry(term: "precision", note: "精确率，与「精度 accuracy」区分"),
            GlossaryEntry(term: "recall", note: "召回率"),
        ]
    )

    // MARK: - AI 工具与提示工程

    /// 这包是照着真实课堂建的：实测那条录音在讲怎么用 AI 工具，
    /// 而当时的默认词表全是训练术语，一个都没覆盖到。
    static let aiTools = CoursePreset(
        id: "ai-tools",
        name: "AI 工具与提示工程",
        summary: "Claude、ChatGPT、Kimi 这类工具名与用法术语",
        entries: [
            GlossaryEntry(
                term: "Claude",
                aliases: ["cludelod Clod", "Clod", "cludelod"],
                note: "Anthropic 的模型；实测被转写成 cludelod Clod"
            ),
            GlossaryEntry(term: "ChatGPT", note: "OpenAI 的对话模型"),
            GlossaryEntry(term: "DeepSeek", note: "深度求索的模型"),
            GlossaryEntry(term: "Kimi", note: "月之暗面的模型"),
            GlossaryEntry(term: "Gemini", note: "Google 的模型"),
            GlossaryEntry(term: "Copilot", note: "微软的编程助手"),
            GlossaryEntry(term: "Cursor", note: "AI 代码编辑器"),
            GlossaryEntry(term: "prompt", note: "提示词"),
            GlossaryEntry(term: "prompt engineering", note: "提示工程"),
            GlossaryEntry(term: "token", note: "词元，模型计费和上下文长度的单位"),
            GlossaryEntry(term: "context window", note: "上下文窗口"),
            GlossaryEntry(term: "API", note: "应用程序接口"),
            GlossaryEntry(term: "fine-tuning", note: "微调"),
            GlossaryEntry(term: "RAG", note: "检索增强生成"),
            GlossaryEntry(term: "embedding", note: "嵌入向量"),
            GlossaryEntry(term: "agent", note: "智能体"),
            GlossaryEntry(term: "hallucination", note: "幻觉，模型编造内容"),
            GlossaryEntry(term: "vector database", note: "向量数据库"),
            GlossaryEntry(term: "LLM", note: "大语言模型"),
            GlossaryEntry(term: "temperature", note: "采样温度参数"),
            GlossaryEntry(term: "MCP", note: "Model Context Protocol"),
            GlossaryEntry(term: "multimodal", note: "多模态"),
        ]
    )

    // MARK: - 编程与开发

    static let programming = CoursePreset(
        id: "programming",
        name: "编程与开发",
        summary: "版本控制、容器、构建部署相关术语",
        entries: [
            GlossaryEntry(term: "git", note: "版本控制工具，小写是官方写法"),
            GlossaryEntry(term: "GitHub", note: "代码托管平台"),
            GlossaryEntry(term: "repository", note: "仓库"),
            GlossaryEntry(term: "commit", note: "提交"),
            GlossaryEntry(term: "branch", note: "分支"),
            GlossaryEntry(term: "merge", note: "合并"),
            GlossaryEntry(term: "pull request", note: "合并请求"),
            GlossaryEntry(term: "conflict", note: "冲突"),
            GlossaryEntry(term: "Docker", note: "容器工具"),
            GlossaryEntry(term: "Kubernetes", note: "容器编排"),
            GlossaryEntry(term: "container", note: "容器"),
            GlossaryEntry(term: "image", note: "镜像"),
            GlossaryEntry(term: "API", note: "应用程序接口"),
            GlossaryEntry(term: "SDK", note: "软件开发工具包"),
            GlossaryEntry(term: "framework", note: "框架"),
            GlossaryEntry(term: "library", note: "库"),
            GlossaryEntry(term: "compiler", note: "编译器"),
            GlossaryEntry(term: "runtime", note: "运行时"),
            GlossaryEntry(term: "debug", note: "调试"),
            GlossaryEntry(term: "deploy", note: "部署"),
            GlossaryEntry(term: "refactor", note: "重构"),
            GlossaryEntry(term: "unit test", note: "单元测试"),
            GlossaryEntry(term: "dependency", note: "依赖"),
            GlossaryEntry(term: "interface", note: "接口"),
            GlossaryEntry(term: "callback", note: "回调"),
            GlossaryEntry(term: "recursion", note: "递归"),
        ]
    )

    // MARK: - 高等数学

    static let mathematics = CoursePreset(
        id: "mathematics",
        name: "高等数学 / 线性代数",
        summary: "微积分、线性代数、复变函数相关术语",
        entries: [
            GlossaryEntry(term: "matrix", note: "矩阵，复数是 matrices"),
            GlossaryEntry(term: "eigenvalue", note: "特征值"),
            GlossaryEntry(term: "eigenvector", note: "特征向量"),
            GlossaryEntry(term: "determinant", note: "行列式"),
            GlossaryEntry(term: "trace", note: "迹，与「追踪」区分"),
            GlossaryEntry(term: "transpose", note: "转置"),
            GlossaryEntry(term: "derivative", note: "导数"),
            GlossaryEntry(term: "partial derivative", note: "偏导数"),
            GlossaryEntry(term: "integral", note: "积分"),
            GlossaryEntry(term: "limit", note: "极限"),
            GlossaryEntry(term: "vector", note: "向量"),
            GlossaryEntry(term: "gradient", note: "梯度"),
            GlossaryEntry(term: "divergence", note: "散度；在训练语境里是「发散」，看上下文"),
            GlossaryEntry(term: "curl", note: "旋度"),
            GlossaryEntry(term: "Jacobian", note: "雅可比矩阵"),
            GlossaryEntry(term: "Fourier transform", note: "傅里叶变换"),
            GlossaryEntry(term: "Laplace transform", note: "拉普拉斯变换"),
            GlossaryEntry(term: "differential equation", note: "微分方程"),
            GlossaryEntry(term: "convergence", note: "收敛"),
            GlossaryEntry(term: "series", note: "级数"),
            GlossaryEntry(term: "orthogonal", note: "正交"),
            GlossaryEntry(term: "linearly independent", note: "线性无关"),
        ]
    )

    // MARK: - 大学物理

    static let physics = CoursePreset(
        id: "physics",
        name: "大学物理",
        summary: "力学、热学、电磁学、光学相关术语",
        entries: [
            GlossaryEntry(term: "velocity", note: "速度，矢量"),
            GlossaryEntry(term: "acceleration", note: "加速度"),
            GlossaryEntry(term: "momentum", note: "动量"),
            GlossaryEntry(term: "inertia", note: "惯性"),
            GlossaryEntry(term: "torque", note: "力矩"),
            GlossaryEntry(term: "entropy", note: "熵"),
            GlossaryEntry(term: "enthalpy", note: "焓"),
            GlossaryEntry(term: "wavelength", note: "波长"),
            GlossaryEntry(term: "frequency", note: "频率"),
            GlossaryEntry(term: "amplitude", note: "振幅"),
            GlossaryEntry(term: "refraction", note: "折射"),
            GlossaryEntry(term: "diffraction", note: "衍射"),
            GlossaryEntry(term: "interference", note: "干涉"),
            GlossaryEntry(term: "capacitor", note: "电容"),
            GlossaryEntry(term: "inductor", note: "电感"),
            GlossaryEntry(term: "voltage", note: "电压"),
            GlossaryEntry(term: "resistance", note: "电阻"),
            GlossaryEntry(term: "magnetic field", note: "磁场"),
            GlossaryEntry(term: "photon", note: "光子"),
            GlossaryEntry(term: "relativity", note: "相对论"),
            GlossaryEntry(term: "quantum", note: "量子"),
        ]
    )

    // MARK: - 经济学

    static let economics = CoursePreset(
        id: "economics",
        name: "经济学 / 金融",
        summary: "宏观微观、货币政策相关术语",
        entries: [
            GlossaryEntry(term: "GDP", note: "国内生产总值"),
            GlossaryEntry(term: "inflation", note: "通货膨胀"),
            GlossaryEntry(term: "deflation", note: "通货紧缩"),
            GlossaryEntry(term: "demand", note: "需求"),
            GlossaryEntry(term: "supply", note: "供给"),
            GlossaryEntry(term: "elasticity", note: "弹性"),
            GlossaryEntry(term: "monopoly", note: "垄断"),
            GlossaryEntry(term: "oligopoly", note: "寡头"),
            GlossaryEntry(term: "marginal cost", note: "边际成本"),
            GlossaryEntry(term: "opportunity cost", note: "机会成本"),
            GlossaryEntry(term: "fiscal policy", note: "财政政策"),
            GlossaryEntry(term: "monetary policy", note: "货币政策"),
            GlossaryEntry(term: "interest rate", note: "利率"),
            GlossaryEntry(term: "exchange rate", note: "汇率"),
            GlossaryEntry(term: "equilibrium", note: "均衡"),
            GlossaryEntry(term: "utility", note: "效用"),
            GlossaryEntry(term: "liquidity", note: "流动性"),
            GlossaryEntry(term: "portfolio", note: "投资组合"),
        ]
    )
}
