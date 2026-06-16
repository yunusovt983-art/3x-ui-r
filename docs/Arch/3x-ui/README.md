# DDD-реконструкция 3x-ui (исходная система)

> Реконструкция предметной области панели [3x-ui](https://github.com/MHSanaei/3x-ui) (Go, `v3.3.1`)
> сквозь призму DDD. Это разбор **системы-источника**, из которого мы извлекаем модель для
> проектирования нашей панели на Rust.

Симметрично [`../shoes/`](../shoes/README.md) (разбор data-plane на Rust). Документы про **наш**
Rust-проект (redesign, обзор экосистемы, лицензии, идеи) лежат уровнем выше, в [`../`](../README.md).

## Документы

| Файл | О чём |
|------|-------|
| [01-context-and-vision.md](01-context-and-vision.md) | Системный контекст, акторы, внешние системы, цель проекта на Rust |
| [02-ubiquitous-language.md](02-ubiquitous-language.md) | Единый язык (глоссарий домена) — фундамент DDD |
| [03-bounded-contexts.md](03-bounded-contexts.md) | Ограниченные контексты и карта контекстов (Context Map) |
| [04-domain-model.md](04-domain-model.md) | Агрегаты, сущности, value objects, инварианты, доменные события |
| [05-current-architecture-go.md](05-current-architecture-go.md) | Текущая слоистая Go-архитектура «как есть» (что заимствуем, что отбрасываем) |

## Подпапки: DDD-исследования ключевых зависимостей

Наиболее важные для домена 3x-ui зависимости из `Vendor/`, разобранные в стиле DDD:

| Подпапка | Зависимость | Лиц. | Роль для 3x-ui |
|----------|-------------|------|-----------------|
| [xray-core/](xray-core/README.md) | xtls/xray-core | MPL-2.0 | Движок data-plane за ACL **BC-2**; gRPC-API + формат конфига + счётчики трафика — главный контракт |
| [reality/](reality/README.md) | xtls/reality | MPL-2.0 | Анти-цензурный транспорт; модель `StreamSettings::Reality`, генерация ключей |
| [utls/](utls/README.md) | refraction/utls | BSD-3 | Подделка TLS-fingerprint; поле `fingerprint` (chrome/firefox/…) |
| [telego/](telego/README.md) | mymmrac/telego | MIT | Telegram-бот (**BC-8**); паттерны для `teloxide` на Rust |
| [wireguard/](wireguard/README.md) | wireguard-go | MIT | WireGuard inbound — идентичность по публичному ключу (отдельный агрегат, не VLESS-клиент) |
| [quic-hysteria/](quic-hysteria/README.md) | quic-go + apernet | MIT | QUIC-транспорты Hysteria2/TUIC; Brutal CC (bandwidth как доменный параметр) |
| [shadowsocks/](shadowsocks/README.md) | sing-shadowsocks + sing | GPL | Shadowsocks 2022 (BLAKE3, EIH-мультиюзер) — естественный per-user PSK |
| [dns/](dns/README.md) | miekg/dns | BSD-3 | DNS-подсистема (резолверы, fakedns, query-strategy); секция `dns` = рестартная |

## Связь с остальной документацией

- Целевой Rust-редизайн на основе этой модели → [`../06-rust-redesign.md`](../06-rust-redesign.md)
- Обзор Rust-экосистемы → [`../07-rust-ecosystem-survey.md`](../07-rust-ecosystem-survey.md)
- Лицензии (3x-ui под GPL-3.0 → clean-room) → [`../08-licensing-compliance.md`](../08-licensing-compliance.md)
- Идеи из Rust-проектов → [`../09-ideas-from-rust-projects.md`](../09-ideas-from-rust-projects.md)

---
*Источник: `../../../Vendor/3x-ui` @ `37c5e0b` (`v3.3.1`, GPL-3.0). Анализ идейный (clean-room).*
