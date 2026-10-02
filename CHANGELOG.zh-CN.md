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

- 渲染要求 Ebox framework SPI v3 与 `ebox-publication/v1`。Host final-accept
  authority 与 committed query guard 均使用 Ebox transaction。
  请先升级 Ebox，再升级 ETAF，重启 Emacs 以加载同一套 provider 与 render port。
  性能报告通过 `:publication-transaction-id` 将 `ebox-publication` stage 与
  Ebox 渲染关联。

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
