# 02 — Единый язык (Ubiquitous Language)

Единый язык — фундамент DDD: код, документация и разговоры с экспертом домена используют **одни и те же
термины**. Ниже — глоссарий, извлечённый из исходников 3x-ui. Эти термины должны стать именами типов,
модулей и методов в Rust-версии (колонка «Rust-имя» — предложение).

## 2.1. Ядро домена

| Термин | Значение в 3x-ui | Rust-имя |
|--------|------------------|----------|
| **Inbound** | Точка входа: слушающий порт + протокол + транспорт + список клиентов. Единица конфигурации Xray. | `Inbound` (агрегат) |
| **Client** | Конечный пользователь VPN. Идентифицируется уникальным `email`, имеет креденшелы (UUID/пароль/flow), лимиты и срок. Может жить на нескольких инбаундах. | `Client` (агрегат) |
| **Protocol** | vless / vmess / trojan / shadowsocks / hysteria / http / mixed / wireguard / mtproto / tunnel | `enum Protocol` |
| **Stream Settings** | Транспорт + безопасность инбаунда: tcp/ws/grpc/http2 × tls/reality/none | `StreamSettings` (VO) |
| **Traffic** | Учёт байт: `up` (отдано) + `down` (принято). Бывает per-inbound, per-client, per-outbound. | `Traffic { up, down }` (VO) |
| **Quota / Total** | Лимит трафика клиента в байтах. `0` = безлимит. При превышении клиент отключается. | `Quota` (VO) |
| **Expiry** | Срок действия (unix ms). `0` = бессрочно. При наступлении — отключение. | `ExpiryTime` (VO) |
| **Limit IP** | Макс. число одновременных IP у клиента. Превышение → блок/отключение. | `IpLimit` (VO) |
| **Tag** | Уникальный строковый идентификатор инбаунда/аутбаунда внутри Xray. Через него работает gRPC API. | `Tag` (newtype) |
| **Reset period** | Период автосброса трафика инбаунда: never/hourly/daily/weekly/monthly. | `enum ResetPeriod` |

## 2.2. Подписки (Subscription)

| Термин | Значение | Rust-имя |
|--------|----------|----------|
| **Subscription / Sub** | Набор ссылок для клиента, собранный по его `subId`. Отдаётся отдельным HTTP-сервером. | `Subscription` |
| **SubID** | Идентификатор, объединяющий клиента на разных инбаундах в одну подписку. | `SubId` (newtype) |
| **Share link** | Текстовая ссылка-конфиг: `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `tg://proxy`. | `ShareLink` |
| **Clash config** | YAML-формат подписки (proxies + proxy-groups + rules) для клиентов Clash. | `ClashConfig` |
| **JSON sub** | Подписка в виде Xray-аутбаундов (готовый клиентский JSON). | `JsonSubscription` |
| **External link** | Сторонняя ссылка/подписка, импортированная в клиента и подмешиваемая в его подписку. | `ExternalLink` |
| **Remark** | Человекочитаемая метка ссылки (имя инбаунда + email + дата). | `Remark` |

## 2.3. Xray-процесс и применение конфигурации

| Термин | Значение | Rust-имя |
|--------|----------|----------|
| **Xray process** | Дочерний процесс `xray -c config.json`, которым управляет панель (start/stop/restart). | `XrayProcess` |
| **Xray API** | gRPC-интерфейс работающего ядра: Handler/Stats/Routing services. | `XrayApi` (порт) |
| **Hot-diff** | Сравнение старого и нового конфигов: что можно применить «на горячую» через gRPC, а что требует рестарта. **Центральная доменная идея.** | `HotDiff` |
| **Hot-reloadable секции** | inbounds, outbounds, routing.rules, routing.balancers — применяются без рестарта. | — |
| **Restart-required секции** | log, dns, policy, api, stats, transport, fakedns, observatory, metrics — требуют рестарта. | — |
| **API inbound** | Служебный инбаунд, через который панель говорит с ядром. **Неизменяем на горячую.** | — |
| **Default outbound** | Первый аутбаунд — дефолтный обработчик Xray. **Неизменяем на горячую.** | — |
| **Online grace window** | Окно (мс), внутри которого клиент считается «онлайн» по последнему трафику. | `GraceWindow` (VO) |

## 2.4. Federation (мульти-нода)

| Термин | Значение | Rust-имя |
|--------|----------|----------|
| **Node** | Удалённая панель-точка-выхода, зарегистрированная у мастера. | `Node` (агрегат) |
| **GUID** | Стабильный самоидентификатор ноды (приходит в heartbeat). Ключ агрегации онлайна. | `NodeGuid` (newtype) |
| **Heartbeat** | Периодический пинг статуса/метрик ноды. | `Heartbeat` |
| **Trust mode** | Режим проверки TLS ноды: verify / skip / pin / mtls. | `enum TrustMode` |
| **Inbound sync mode** | Что синхронизировать на ноду: all / selected (по тегам). | `enum SyncMode` |
| **Node online tree** | Поддерево онлайн-клиентов, привязанное к GUID ноды (для корректной агрегации в кластере). | `NodeOnlineTree` |
| **Global traffic** | Агрегированный кросс-панельный учёт квоты, который мастер «пушит» нодам. | `ClientGlobalTraffic` |

## 2.5. Поддерживающие термины

| Термин | Значение | Rust-имя |
|--------|----------|----------|
| **Setting** | Глобальная настройка панели (key-value): web-порт, sub-сервер, TLS, бот, LDAP, SMTP, 2FA, mTLS. | `Settings` (агрегат) |
| **Fallback** | Перенаправление по ALPN/path для VLESS/Trojan TLS: «мастер»-инбаунд представляет внешне «дочерние» (loopback/unix-socket). | `Fallback` |
| **Domain event** | Факт, произошедший в домене: `xray.crash`, `node.down`, `cpu.high`, `login.attempt`, `outbound.down`. | `enum DomainEvent` |
| **Group** | Логическая группировка клиентов. | `ClientGroup` |
| **MTProto instance** | Sidecar-процесс `mtg` для Telegram-MTProto-прокси. | `MtprotoInstance` |

> **Правило для Rust-кода:** если термина нет в этом списке — его нет в домене. Прежде чем вводить
> новое существительное в коде, оно добавляется сюда и согласуется. Это и есть дисциплина Ubiquitous Language.
