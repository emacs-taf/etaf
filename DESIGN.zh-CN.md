# 设计规范

## 事实来源
- 状态：生效中
- 最近更新：2026-08-05
- 主要产品界面：`examples/` 下的可执行应用，尤其是三个 `etaf-*-example-open` 命令打开的缓冲区。
- 已审阅证据：ETAF 公开源码与用户指南、core/Data/Resource 测试、`../etaf-playground/DESIGN.md`、精修后的 ETAF Showcase，以及原始 Ebox Flex 参考示例。

## 品牌
- 气质：精确、克制、现代、技术化，并且经过明确构图。
- 可信信号：稳定的几何结构、清晰的对比度、明确的状态所有权、只使用公开 API，以及可见的成功/错误/选择状态。
- 避免：裸 fixture 文本、低对比度浅色文字、装饰性 emoji、假浏览器外壳、无意义的大面积留白，以及与正文无法区分的控件。

## 产品目标
- 目标：通过小型可执行文件提供可复制的 ETAF core 最佳实践；证明已安装 Runtime 的真实交互路径；让视觉质量与 Flex 参考和 ETAF Showcase 保持一致。
- 非目标：替代 `etaf-playground`、假装缺失的 `etaf-ui` 目录已经存在、引入第二套主题系统，或在一个应用里展示全部公开符号。
- 成功信号：每个示例只讲清一个所有权边界；加载文件时不产生应用副作用；通过公开事件响应；正确清理资源；在紧凑 GUI 窗口中不裁切。

## 用户与任务
- 主要用户：ETAF 应用作者和框架维护者。
- 用户任务：复制正确的状态/Data/Resource 模式、检查真实挂载应用，并验证事件产生的可见结果。
- 主要环境：源码阅读、GUI Emacs 探索、自动化 ERT 和框架回归审查。

## 信息架构
- 主导航：不增加共享 launcher；每个文件拥有一个明确的 open 与 close 命令。
- 核心界面：保留式计数器、任务 Data Controller、Resource 健康状态。
- 内容层级：能力 eyebrow、应用标题与说明、主要状态区域、操作区、所有权规则页脚。

## 设计原则
- 原则一：一个示例只讲一个 lifecycle owner；避免用 mega-demo 隐藏状态与清理的归属。
- 原则二：写操作发生在 Event、Action、lifecycle、Data 或 Resource 边界；render 函数保持只读。
- 原则三：使用暖色、克制的语义色和一像素边框呈现结构，不增加设计系统依赖。
- 取舍：独立示例采用固定的紧凑教学画布；完整 viewport 响应式应用继续由 `etaf-playground` 展示。

## 视觉语言
- 颜色：暖色画布 `#F8F5EE`、纸张 `#FFFDF8`、正文 `#252A2E`、弱化正文 `#66706A`、陶土色 `#F1D4C9`、鼠尾草绿 `#DCEBDD`、蓝色 `#D9EAF2` 与紫色 `#E7E2F1`，始终搭配明确的深色文字。
- 字体：沿用 Emacs 当前等宽字体；粗体只用于标题、操作、状态和关键数值。
- 间距：一行纵向间隔、10–12 px 水平间隔、12–18 px 表面内边距。
- 形状与层级：方正的文本原生区块和一像素边框；不使用阴影或伪圆角。
- 动效：无；同步 commit 后几何结构必须稳定。
- 图像与图标：只使用文本和选择圆点等克制语义标记。

## 组件
- 复用能力：core Host、保留式 Component、ref、computed、Action、focusable Behavior、Data Controller、Resource 与 Runtime lifecycle callback。
- 新增或调整：示例专用 shell、metric、action、row、status 与 footer Component/Host。
- 状态：ready/active 计数器、selected/unselected 任务、open/done 筛选、idle/loading/success/error Resource。
- 所有权：每个示例拥有自己的小型静态配色和组合；ETAF/Ebox 拥有语义、布局和渲染。

## 可访问性
- 目标：高对比、可通过键盘寻址的文本 UI。
- 键盘与焦点：每个操作都具有稳定 ref、button role 和 `etaf-focusable` Behavior。
- 对比度：着色表面始终显式设置前景色；状态同时使用文字和颜色表达。
- 语义：保留文字标签和语义 role，不只用装饰表达含义。
- 动效：不使用动画或闪烁状态。

## 响应式行为
- 支持范围：正文宽度约 760 px 及以上的 GUI Emacs。
- 布局适配：示例使用 680–720 px 教学画布；操作组使用可换行 Flex；完整 viewport 响应式模式留在 `etaf-playground`。
- 触控/悬停：无；交互使用 Runtime event 边界。

## 交互状态
- Loading：明确显示 Resource/Data 状态，不伪造 fallback。
- Empty：有边界的解释行，不填充隐藏的占位数据。
- Error：高对比、持续可见的错误文案，直到下一次操作。
- Success：鼠尾草绿表面和明确状态文字。
- Disabled：移除 event/tab stop，不展示误导性的可用控件。
- 离线/慢网络：同步 core 示例不适用。

## 内容语气
- 风格：直接、技术化、简洁、适合教学。
- 术语：统一使用 View、Component、Host、Runtime、Data Controller、Resource、Event、Action、Scope 与 public API。
- 文案规则：点明展示的所有权边界与可见操作效果，避免宣传式填充文字。

## 实现约束
- 技术边界：Emacs 29.1+、公开 `etaf` facade，以及通过 ETAF Host 下沉的公开 Ebox 属性。
- Token：直接复用既有暖色配色；不为三个示例增加 token 框架。
- 性能：只使用同步、有界数据；不使用 timer、后台工作或隐藏的重复 mount。
- 兼容性：core 示例不得依赖 `etaf-ui`、`etaf-sqlite`、`etaf-playground`，也不得调用私有 `etaf--*` / `ebox--*` API。
- 验证：`make check` 会编译示例并驱动已挂载的公开事件路径；GUI 验证只使用一个目标缓冲区窗口，并拒绝裁切或续行标记。

## 待解决问题
- [ ] 只有 ETAF 定义公开异步完成契约后才增加异步 Resource 示例；维护者；避免教授臆造 API。
