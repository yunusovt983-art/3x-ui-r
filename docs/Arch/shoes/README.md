# Архитектура `cfal/shoes` сквозь призму DDD

> Реконструкция архитектуры прокси-сервера [`cfal/shoes`](https://github.com/cfal/shoes) (Rust, MIT,
> `607ccde`) в терминах Domain-Driven Design. Цель — понять, **как устроено зрелое мульти-протокольное
> прокси-ядро на Rust**, чтобы (а) оценить его как кандидата на data-plane для пути B и
> (б) перенять архитектурные идеи в нашу панель (см. [`../09-ideas-from-rust-projects.md`](../09-ideas-from-rust-projects.md)).

Это **описание существующего кода** через DDD-оптику, а не проектирование. Анализ идейный
(clean-room, см. [`../08-licensing-compliance.md`](../08-licensing-compliance.md)); shoes под MIT,
поэтому при пути B возможен и кодовый переиспользование.

## Что такое shoes (в одном абзаце)

shoes — **высокопроизводительный мульти-протокольный прокси-сервер** (data-plane). Он принимает
входящие соединения по десятку протоколов (VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, SOCKS5,
HTTP, Snell, AnyTLS, NaiveProxy), оборачивает их транспортами (TLS, WebSocket, **XTLS Reality**,
**Vision**, ShadowTLS, QUIC), по правилам маршрутизации выбирает исходящую цепочку прокси (multi-hop с
балансировкой), устанавливает upstream-соединение и **прокачивает байты в обе стороны**. Конфиг —
декларативный YAML с горячей перезагрузкой. Управляющего API (add/remove user на лету, per-user
статистика) у shoes **нет** — это чистый data-plane, что и есть ключевое ограничение для пути B.

## Карта документов

| Файл | О чём |
|------|-------|
| [01-context-and-vision.md](01-context-and-vision.md) | Системный контекст: что делает shoes, акторы, внешние системы, границы |
| [02-ubiquitous-language.md](02-ubiquitous-language.md) | Единый язык: handler, connector, chain, selector, rule, transport, AsyncStream |
| [03-bounded-contexts.md](03-bounded-contexts.md) | Внутренние ограниченные контексты shoes и карта контекстов |
| [04-domain-model.md](04-domain-model.md) | Агрегаты, сущности, value objects, инварианты, ключевые traits |
| [05-core-domain-data-path.md](05-core-domain-data-path.md) | Ядро домена: сквозной поток одного проксированного соединения (TCP/UDP/TUN) |
| [06-patterns-and-takeaways.md](06-patterns-and-takeaways.md) | Архитектурные паттерны и что переносим в наш проект |

## Ключевой вывод (TL;DR)

1. **Ядро домена shoes — это «жизненный цикл проксированного соединения»**: `accept → handshake
   (inbound handler) → judge (routing) → connect chain (outbound) → copy_bidirectional`. Всё остальное
   (протоколы, транспорты, DNS) — поддерживающие контексты вокруг этого пути.
2. **Полиморфизм через trait'ы — становой хребет.** `AsyncStream` (унифицирует TCP/TLS/WS/QUIC),
   `TcpServerHandler` / `TcpClientHandler` (протоколы), `ProxyConnector` / `SocketConnector` (исходящее),
   `Resolver` (DNS). Конфиг-enum → конкретный trait-объект через фабрики.
3. **Транспорты — декораторы над `AsyncStream`.** TLS оборачивает TCP, Vision оборачивает TLS, протокол
   читает из Vision. Композиция стеков — вложенными обёртками.
4. **Конфиг декларативный и типизированный** (serde + `deny_unknown_fields` + умные helper-типы),
   hot-reload — атомарный рестарт всего пула серверов.
5. **Управляющего слоя нет** — это валидирует наш путь A (панель = ценность в control-plane, которого у
   ядра нет).

---
*Источник: `../../../Vendor/shoes` @ `607ccde` (MIT). Анализ построен на чтении исходников; идейный, без переноса кода. 2026-06-16.*
