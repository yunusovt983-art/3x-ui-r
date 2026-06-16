# 02 — Единый язык (глоссарий)

Термины извлечены из кода shoes. В скобках — основной тип/файл. Это словарь домена data-plane;
он же помогает не путать понятия shoes с понятиями нашей панели.

## Соединения и потоки

| Термин | Что значит | Где в коде |
|--------|------------|------------|
| **AsyncStream** | Унифицированный двунаправленный байтовый поток (`AsyncRead + AsyncWrite + AsyncPing + Unpin + Send + Sync`). За ним прячется TCP, TLS, WebSocket, QUIC, зашифрованный поток. | `async_stream.rs:173` |
| **AsyncMessageStream** | Поток **датаграмм** (UDP): дискретные сообщения, а не байтовый стрим. Варианты: Targeted / Sourced / Session. | `async_stream.rs` |
| **Server stream** | Входящий поток от клиента (после accept). | `tcp_server.rs` |
| **Client stream** | Исходящий поток к upstream (после прохождения цепочки). | `tcp_handler.rs` |
| **copy_bidirectional** | Перекачка байтов между server- и client-stream до EOF (кольцевой буфер, coop-budget). | `copy_bidirectional.rs:294` |

## Обработчики протоколов

| Термин | Что значит | Где |
|--------|------------|-----|
| **TcpServerHandler** | Trait: принять входящий поток, сделать handshake/auth протокола, вернуть «куда форвардить». | `tcp/tcp_handler.rs:72` |
| **TcpClientHandler** | Trait: сделать исходящий handshake (один хоп цепочки), обернуть поток. | `tcp/tcp_handler.rs:88` |
| **TcpServerSetupResult** | Результат входящего handshake: `TcpForward` / `BidirectionalUdp` / `MultiDirectionalUdp` / `SessionBasedUdp` / `AlreadyHandled`. | `tcp/tcp_handler.rs:10` |
| **InnerProtocol** | Что внутри TLS после терминации: `Normal` / `VisionVless` / `Naive`. | `tls_server_handler.rs:44` |
| **Factory** | `create_tcp_server_handler()` / `create_tcp_client_handler()` — конфиг-enum → конкретный handler. | `tcp/*_handler_factory.rs` |

## Маршрутизация и исходящее

| Термин | Что значит | Где |
|--------|------------|-----|
| **ClientProxySelector** | «Судья»: по адресу назначения выбирает решение (chain или block). Метод `judge()`. | `client_proxy_selector.rs:191` |
| **ConnectRule** | Правило: набор масок (`NetLocationMask`) + действие (`ConnectAction`). | `client_proxy_selector.rs:114` |
| **ConnectAction** | `Allow { override_address?, chain_group }` или `Block`. | `client_proxy_selector.rs:126` |
| **ClientProxyChain** | Multi-hop цепочка исходящих прокси с per-hop round-robin балансировкой. | `client_proxy_chain.rs:79` |
| **InitialHopEntry** | Хоп 0: атомарная пара `socket + (опц.) proxy`. | `client_proxy_chain.rs:38` |
| **SocketConnector** | Trait: «создать сокет до X» (хоп 0). | `tcp/socket_connector.rs` |
| **ProxyConnector** | Trait: «обернуть имеющийся поток протоколом Y, туннелировать к Z» (любой хоп). | `tcp/proxy_connector.rs` |

## Адреса и имена

| Термин | Что значит | Где |
|--------|------------|-----|
| **Address** | enum: `Ipv4` / `Ipv6` / `Hostname`. | `address.rs:5` |
| **NetLocation** | `Address + port`. | `address.rs:85` |
| **ResolvedLocation** | `NetLocation + опц. resolved SocketAddr` — кэш ленивого резолва. | `address.rs:179` |
| **Resolver** | Trait DNS: `resolve_location()`. Реализации: Native, Caching, Composite, Hickory, Timeout, Refreshing. | `resolver.rs:19` |

## Транспорты и крипто

| Термин | Что значит | Где |
|--------|------------|-----|
| **Transport** | enum: `Tcp` (default) / `Quic` / `Udp`. | `config/types/transport.rs:29` |
| **CryptoConnection** | Унифицирующий enum над `rustls::{Server,Client}Connection` и REALITY-соединениями. | `crypto/crypto_connection.rs:38` |
| **CryptoTlsStream** | Обёртка `AsyncStream`, реализующая шифрование через `CryptoConnection`. | `crypto/crypto_tls_stream.rs` |
| **REALITY** | Анти-probing TLS: зеркалирование к camouflage-dest, аутентификация по short_id/ECDH, fallback при провале. | `reality/*` |
| **Vision (XTLS)** | Падинг не-TLS трафика под TLS + переключение в Direct-режим (zero-copy) когда видно ApplicationData. | `vless/vision_*` |
| **ShadowTLS** | Маскировка под рукопожатие к настоящему TLS-сайту. | `shadow_tls_*` |

## Конфиг

| Термин | Что значит | Где |
|--------|------------|-----|
| **Config** | Верхнеуровневый enum YAML-объекта: `Server` / `TunServer` / `ClientConfigGroup` / `RuleConfigGroup` / `DnsConfigGroup` / `NamedPem`. | `config/types/groups.rs:151` |
| **ConfigSelection\<T\>** | Значение **инлайн** или **ссылка на именованную группу** (`Config(T)` / `GroupName(String)`). | `config/types/selection.rs:8` |
| **NoneOrSome\<T\> / OneOrSome\<T\> / NoneOrOne\<T\>** | Эргономичные serde-типы: «ничего/одно/список», «минимум одно», «опциональное одно». | `option_util.rs` |
| **NamedPem** | Именованный сертификат: «define once, reference everywhere». | `config/types/groups.rs` |
| **ValidatedConfigs** | Результат валидации: `configs: Vec<Config>` (только Server/Tun) + `dns_groups`. | `config/validate.rs:25` |

## Учёт и идентичность

| Термин | Что значит | Где |
|--------|------------|-----|
| **ActivityTracker** | Per-connection трекер последней активности (atomic ms), для idle-таймаутов. | `h2mux/activity_tracker.rs:24` |
| **ActivityTrackedStream** | Обёртка потока, дёргающая `record_activity()` на read/write. | `h2mux/activity_tracked_stream.rs:15` |
| **UserLookup** | `BLAKE3(hash) → user index`, O(1) lookup + constant-time сравнение. | `naiveproxy/user_lookup.rs:19` |

## TUN

| Термин | Что значит | Где |
|--------|------------|-----|
| **TcpStackDirect** | OS-поток с userspace TCP/IP-стеком (smoltcp): L3-пакеты ↔ L4-соединения. | `tun/tcp_stack_direct.rs:119` |
| **TcpConnectionControl** | Состояние одного TCP-соединения в стеке: ring-буферы + wakers + state machine. | `tun/tcp_conn.rs:21` |
