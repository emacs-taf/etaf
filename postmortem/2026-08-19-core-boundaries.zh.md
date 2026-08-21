# 移除 `.etaf` pair 后的 core 边界

当前 core 移除了只读 data `.etaf`、同名 `.el` companion 的 pair 主路径。它在 compiler 契约尚未存在时增加了第二套文件语法、companion 执行边界和 registry 校验面。不能把 `emacs-box` 的归档 DSL 当捷径复用：它的所有权和可执行语义不同。未来 `.etaf` SFC 应属于 compiler layer，并输出既有的 `etaf-view` 与 `etaf-define-component` 契约。

当前 Component definition 仍是唯一的结构/样式/行为单元：`:view` 负责结构，`:styles` 负责 presentation，`:setup` 负责 retained state、Action 和生命周期。样式 scope 现在在嵌套 Component 内部边界停止；调用者提供的 slot 内容保留 caller scope，子组件自有的 slot fallback 保留 child scope。

挂载后的输入仍走窄的 Runtime 生命周期路径：成功 mount 后启用 input minor mode，unmount 前禁用。TAB/backtab、RET 和 mouse-1 复用公共 focus/hit-test 操作，不建立第二套事件层。
