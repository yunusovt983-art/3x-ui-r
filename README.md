# 3x-ui-r — проектирование 3x-ui на Rust

Исследовательско-архитектурный репозиторий: **переосмысление панели управления Xray-core
[3x-ui](https://github.com/MHSanaei/3x-ui) на Rust** по принципам Domain-Driven Design.

Это не порт Go-кода, а **реконструкция предметной области** и целевая архитектура с нуля.
Анализ выполнен в стиле clean-room (извлекаем идеи/форматы/контракты, не копируем чужой код).

## Содержание

Вся работа — в [`docs/Arch/`](docs/Arch/README.md):

- **[3x-ui/](docs/Arch/3x-ui/README.md)** — DDD-реконструкция исходной системы 3x-ui (контекст, единый
  язык, ограниченные контексты, доменная модель, текущая Go-архитектура) + DDD-разбор ключевых
  зависимостей: [xray-core](docs/Arch/3x-ui/xray-core/README.md), [reality](docs/Arch/3x-ui/reality/README.md),
  [utls](docs/Arch/3x-ui/utls/README.md), [telego](docs/Arch/3x-ui/telego/README.md).
- **[shoes/](docs/Arch/shoes/README.md)** — DDD-разбор Rust-прокси-ядра `cfal/shoes` (кандидат на data-plane).
- **[06-rust-redesign](docs/Arch/06-rust-redesign.md)** — целевая архитектура на Rust (стек, crate'ы, порты/адаптеры).
- **[07-rust-ecosystem-survey](docs/Arch/07-rust-ecosystem-survey.md)** — обзор Rust-экосистемы по теме.
- **[08-licensing-compliance](docs/Arch/08-licensing-compliance.md)** — лицензионная совместимость (clean-room, ACL вокруг xray).
- **[09-ideas-from-rust-projects](docs/Arch/09-ideas-from-rust-projects.md)** — извлечённые идеи.

## Ключевая стратегия

**Путь A:** панель на Rust + `xray-core` (Go) как внешний движок data-plane за Anti-Corruption Layer
через gRPC (`tonic`). Прокси-ядро не переписываем — ценность в control-plane (лимиты, подписки,
hot-diff конфигурации, federation).

## Зависимости (Vendor)

Папка `Vendor/` (исходники 3x-ui, shoes и тематических зависимостей) **не хранится в репозитории** —
это справочный материал. Воспроизводится скриптом:

```bash
bash clone_vendor.sh   # shallow-клоны тематических зависимостей в Vendor/
```
