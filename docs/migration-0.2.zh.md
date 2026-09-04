# 迁移到 ETAF 0.2

ETAF 0.2.1 要求 Ebox 3.0.0 与 TP 2.0.0。安装顺序为 TP、Ebox、ETAF。
renderer bootstrap 现在强制要求 Ebox framework SPI v2；provider 缺失、格式错误
或不兼容时会 fail closed。

请删除所有 `etaf-render-port-selection-policy` 配置。v1 render port 及其 initial
publication 手工清理路径已经退役。Runtime mount 与 update 始终使用不可变的 SPI
v2 port，并保留配对 framework stage/rollback、同对象 report、observation replay、
revision 与 Host final marker 契约。

按依赖顺序从源码升级时，ETAF 接受 Ebox 报告
`tp-transaction-protocol-v1+v2` 或 `tp-transaction-protocol-v2`。前者只是包含所需
v2 协议的过渡期能力声明；ETAF 不会调用 v1 transaction operation。
