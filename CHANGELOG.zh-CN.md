# 更新记录

## Unreleased

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
