# 设计规范

## 事实来源
- 状态：生效中
- 最近更新：2026-08-24
- 主要产品界面：`examples/` 下的可执行应用，以及用于检查任意已挂载应用的通用 ETAF 性能记录器/面板。
- 已审阅证据：ETAF 公开源码与用户指南、core/Data/Resource 测试、`../etaf-playground/DESIGN.md`、Research Shelf 集成基准、Ebox 性能评估器与架构分析、TP surface report，以及原始 Ebox Flex 参考示例。

## 品牌
- 气质：精确、克制、现代、技术化，并且经过明确构图。
- 可信信号：稳定的几何结构、清晰的对比度、明确的状态所有权、只使用公开 API，以及可见的成功/错误/选择状态。
- 避免：裸 fixture 文本、低对比度浅色文字、装饰性 emoji、假浏览器外壳、无意义的大面积留白，以及与正文无法区分的控件。

## 产品目标
- 目标：通过小型可执行文件提供可复制的 ETAF core 最佳实践；证明已安装 Runtime 的真实交互路径；让视觉质量与 Flex 参考和 ETAF Showcase 保持一致；让每个公共操作的跨包延迟都可归因到具体嵌套阶段。
- 非目标：替代 `etaf-playground`、假装缺失的 `etaf-ui` 目录已经存在、引入第二套主题系统、在一个应用里展示全部公开符号，或把性能分析绑定到某个示例/应用包。
- 成功信号：每个示例只讲清一个所有权边界；加载文件时不产生应用副作用；通过公开事件响应；正确清理资源；在紧凑 GUI 窗口中不裁切。性能面板可记录任意挂载应用，保持操作返回值/错误，展示 inclusive 与 exclusive 阶段耗时，并保留有界历史。

## 用户与任务
- 主要用户：ETAF 应用作者和框架维护者。
- 用户任务：复制正确的状态/Data/Resource 模式、检查真实挂载应用、验证事件产生的可见结果，并定位哪个框架/包阶段承担了操作延迟。
- 主要环境：源码阅读、GUI Emacs 探索、自动化 ERT 和框架回归审查。

## 信息架构
- 主导航：不增加共享 launcher；每个文件拥有一个明确的 open 与 close 命令。
- 核心界面：保留式计数器、任务 Data Controller、Resource 健康状态，以及通用性能记录缓冲区。
- 内容层级：示例使用能力 eyebrow、应用标题与说明、主要状态区域、操作区、所有权规则页脚。性能面板先显示 operation 摘要，再显示带包/类别、inclusive、exclusive、状态和细节的嵌套阶段。

## 设计原则
- 原则一：一个示例只讲一个 lifecycle owner；避免用 mega-demo 隐藏状态与清理的归属。
- 原则二：写操作发生在 Event、Action、lifecycle、Data 或 Resource 边界；render 函数保持只读。
- 原则三：使用暖色、克制的语义色和一像素边框呈现结构，不增加设计系统依赖。
- 原则四：公共 operation 边界只插桩一次，并通过包无关的 stage 注册扩展覆盖面；示例只能作为验证负载，不能成为分析器概念。
- 取舍：独立示例采用固定的紧凑教学画布；完整 viewport 响应式应用继续由 `etaf-playground` 展示。

## 性能架构：三个根原则

### 一、Host/Box 属性是视觉更新单位，Component 不是默认重绘单位

Component 是 setup、状态、Context、slot 和 lifecycle 的计算/所有权边界；它可能
产生一个或多个 Host/Box，也可能透明地只产生 Component、Range 或 fragment，
因此不能把 Component 数据结构直接等同为一个 Box。但一次已经定位到具体视觉
节点的属性变化，不应重新执行产生它的 Component。

Runtime 必须保留结构化属性 delta，而不是把所有响应式依赖压缩成
“Component dirty”：

```text
source-id → semantic-host-id → backend-node-id → property → old/new → impact
```

更新层级按确定性从小到大选择：

- `paint`：直接更新 Host/Box 的属性贡献，不执行 Component、不运行布局；
- `content` 或局部 geometry：只重算对应 Box 及精确布局依赖闭包；
- control flow、slot、列表拓扑或 lifecycle：执行拥有该结构的 Component；
- 来源不可信、外部 buffer 被改写或索引缺失：显式进入 root fallback。

Theme 是第一条垂直实现：Theme token 编译为 property binding；palette 变化只调度
绑定到颜色、背景和边框属性的 Host。只有 `Light theme`/`Dark theme` 等真实内容
变化继续调度它自己的 Component/Range。

### 二、权威依赖状态替代热路径上的重复 proof

初次布局应产出并持有权威状态：父链、分配 slot、containment boundary、
property impact、overflow、viewport/display revision 和布局 revision。之后的更新
根据 property schema 与依赖图直接计算 dirty closure，不从渲染后的 buffer 重新
扫描并猜测局部更新是否安全。

- paint delta 对布局没有依赖，必须是零 proof；
- 固定 slot 的内容变化只比较 O(1) revision/token；
- auto/intrinsic 内容变化沿已保存的布局依赖边更新，到 containment boundary 停止；
- 结构或 viewport 变化只失效实际受影响的证书/依赖边；
- 完整 span 扫描和保守 proof 只保留给不可信 candidate、外部 mutation、debug
  assertion 与 fallback，不属于正常交互热路径。

当前 retained allocation certificate 是迁移措施：它把重复 proof 改为一次建立、
后续 revision 校验；最终依赖图完整后，应删除被取代的扫描路径，而不是永久叠加
两套判断逻辑。

### 三、Paint 必须以 TP 有序属性贡献保留到 publication

Theme、Component 样式、交互状态、显式 inline 属性和 focus/selection 是不同的
paint contribution。Ebox 不应在进入 TP 之前把它们压平成每个 fragment 的最终
`face`，也不应在 palette 切换时重新调和所有 fragment。

这里的“层”指 TP properties surface/ledger 中的有序 property contribution，
不是 `tp-layer.el` 的 definition-time recipe。职责边界是：

- ETAF 保留 `source → Host property contribution` 绑定和优先级来源；
- Ebox 保留 Box/role 到稳定 TP range/object 的映射，只报告 layout/content delta；
- TP 合并同一 surface 内的有序属性贡献，拥有 baseline、冲突检测、原子发布、
  回滚和 unmount restoration；
- palette 切换替换 Theme contribution，较高优先级的 Component/state/inline
  contribution 保持不变。

因此换主题的目标路径是：

```text
Theme source changed
→ resolve changed Theme contributions
→ TP properties-only scoped publication
→ redisplay
```

它不得创建新 View、重新执行颜色消费者 Component、运行 Ebox layout、扫描祖先
slot，或遍历完整 fragment ledger。只有真实文本/结构变化走独立的 content/layout
事务；二者仍由同一个上层 ETAF operation 关联并原子提交。

## 视觉语言
- 颜色：暖色画布 `#F8F5EE`、纸张 `#FFFDF8`、正文 `#252A2E`、弱化正文 `#66706A`、陶土色 `#F1D4C9`、鼠尾草绿 `#DCEBDD`、蓝色 `#D9EAF2` 与紫色 `#E7E2F1`，始终搭配明确的深色文字。
- 字体：沿用 Emacs 当前等宽字体；粗体只用于标题、操作、状态和关键数值。
- 间距：一行纵向间隔、10–12 px 水平间隔、12–18 px 表面内边距。
- 形状与层级：方正的文本原生区块和一像素边框；不使用阴影或伪圆角。
- 动效：无；同步 commit 后几何结构必须稳定。
- 图像与图标：只使用文本和选择圆点等克制语义标记。

## 组件
- 复用能力：core Host、保留式 Component、ref、computed、Action、focusable Behavior、Data Controller、Resource 与 Runtime lifecycle callback。
- 新增或调整：示例专用 shell、metric、action、row、status 与 footer Component/Host；一个由通用 operation/stage 记录驱动的 `tabulated-list-mode` 性能面板。
- 状态：ready/active 计数器、selected/unselected 任务、open/done 筛选、idle/loading/success/error Resource；记录器禁用/启用、操作成功/失败、空历史、有界历史，以及在被测热路径之外显式手动刷新。
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
- 性能记录器禁用：说明启用命令，不伪造示例数据。
- 性能历史为空：显示简洁空状态，并说明哪些公共操作会生成记录。
- 操作失败：保留带 error 状态的 timing 记录，同时原始 condition 不变地继续传播。
- 离线/慢网络：同步 core 示例不适用。

## 内容语气
- 风格：直接、技术化、简洁、适合教学。
- 术语：统一使用 View、Component、Host、Runtime、Data Controller、Resource、Event、Action、Scope 与 public API。
- 文案规则：点明展示的所有权边界与可见操作效果，避免宣传式填充文字。

## 实现约束
- 技术边界：Emacs 29.1+、公开 `etaf` facade，以及通过 ETAF Host 下沉的公开 Ebox 属性。
- Token：直接复用既有暖色配色；不为三个示例增加 token 框架。
- 性能：只使用同步、有界数据；不使用 timer、后台工作或隐藏的重复 mount。
- 性能分析：记录必须按需启用、有界、包无关，并保持返回值/error；关闭后可完全移除。默认阶段采用粗粒度边界，第三方包可注册临时细节探针而不产生反向依赖。嵌套 inclusive/exclusive 统计必须成立。
- 兼容性：core 示例不得依赖 `etaf-ui`、`etaf-sqlite`、`etaf-playground`，也不得调用私有 `etaf--*` / `ebox--*` API。
- 验证：`make check` 会编译示例并驱动已挂载的公开事件路径；GUI 验证只使用一个目标缓冲区窗口，并拒绝裁切或续行标记。

## 待解决问题
- [ ] 只有 ETAF 定义公开异步完成契约后才增加异步 Resource 示例；维护者；避免教授臆造 API。
- [ ] GUI redisplay 完成不属于 batch publication timing；在把它展示成同步框架阶段前，需要定义可移植的 Emacs redisplay marker；维护者；避免错误的端到端结论。
