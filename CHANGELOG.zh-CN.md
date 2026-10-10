# 更新记录

## Unreleased

### Added

- 新增 `etaf-list-cache`：给变化很慢的列表提供 stale-while-revalidate 策略。
  每个列表按 key 缓存并记录到达时间，应用先展示缓存、在后台与最新回复对比；
  `etaf-list-cache-next` 一次挑一个列表（最旧的过期项优先，其次是从未加载过的），
  交给会话挂载期间 arm 的定时器。刷新失败会退避，需要人介入的失败会暂停刷新，
  直到某次加载成功；可选的版本令牌让支持条件请求的后端不重绘也能刷新条目。

- 新增 `etaf-draggable` 与 `etaf-resizable` Behavior，将 Ebox 拖拽手势转换为调用方
  持有的响应式几何 ref，支持轴/边选择、边界、生命周期回调和逻辑单位位移转换。
- 新增受控变体，通过 `read`/`on-change` 适配聚合几何状态，不创建第二份持久几何存储。

### Changed

- Runtime 改用细粒度保留架构：`etaf-view` 编译为保留区段，Host 属性与文本读取
  成为逐绑定 effect，Ebox 节点保持挂载，提交只修补 buffer 的局部区域，不再重建
  整棵应用树。普通文本、样式和几何更新的延迟因此下降，Ebox 仍是 ETAF 内部的保留
  节点引擎。
- 迁移：用 `etaf-runtime-revision` 或 `etaf-runtime-flush` 的返回值代替代际 API，
  比较 revision 以确认一次更新已写入 buffer。
- 失败的绑定会丢弃整次更新：buffer、revision 和挂载回调保持上次提交的状态，已写入
  的 ref 保留新值。下一次写入或 `etaf-runtime-flush` 会重试被丢弃的工作，因此在
  修复失败之前，后续更新也会等待。

### 修复

- `:hover-style` plist 里嵌套的 Theme token 现在和其他 Host 样式值一样按
  当前提供的 Theme 解析，目录组件悬停时能正常着色，不再把未解析的 token
  泄漏进原生 mouse face。
- 当有活动的 minibuffer、补全弹窗或 echo area 消息占用显示窗口高度时，窗口
  尺寸结算不再把这段借用高度当成 resize 去重排已挂载的 Runtime。frame 自身
  尺寸变化仍会重排，借用的空间释放后由 `minibuffer-exit-hook` 对账补回。

## 迁移到 ETAF 0.2

ETAF 0.2.1 要求 Ebox 3.0.0。请先升级 Ebox，再升级 ETAF。
renderer bootstrap 现在强制要求 Ebox framework SPI v2；provider 缺失、格式错误
或不兼容时会 fail closed。

请删除所有 `etaf-render-port-selection-policy` 配置。v1 render port 及其 initial
publication 手工清理路径已经退役。Runtime mount 与 update 始终使用不可变的 SPI
v2 port，并保留配对 framework stage/rollback、同对象 report、observation replay、
revision 与 Host final marker 契约。

按依赖顺序从源码升级时，ETAF 使用 Ebox 的 `ebox-publication/v1` 与 SPI v3；
旧的 transaction provider 声明和兼容入口已经删除。
