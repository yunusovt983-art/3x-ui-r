# 09 — Идеи из Rust-проектов (shoes, necko-xray)

> Извлекаем **идеи / форматы / контракты** (не охраняются авторским правом) из двух ближайших
> Rust-проектов и проецируем их на нашу DDD-модель (`03`–`06`). Это **не** перенос кода —
> только архитектурные паттерны (см. правило clean-room в `08`).

## 9.1. Что доступно

| Проект | Статус в `Vendor/` | Лицензия | Что берём |
|--------|--------------------|----------|-----------|
| **[cfal/shoes](https://github.com/cfal/shoes)** | ✅ склонирован (`607ccde`, 2026-05-27, 3.8M) | **MIT** | Идеи + (для пути B) потенциально код |
| **Necko1/necko-xray** | ❌ репозиторий удалён/приватен (git 404) | неизвестна | Только **архитектура** из публичного описания (факты, не код) |

> 🔑 **Лицензионно важное:** `shoes` под **MIT** → permissive, совместимо с **закрытым продуктом**
> (можно use/modify/sublicense). Его транзитивные зависимости (`rustls`, `quinn`, `hickory`, `aws-lc-rs`)
> — MIT/Apache, **без GPL**. Это снимает мою прежнюю осторожность по пути B: лицензионно `shoes` как
> Rust-ядро для закрытого продукта чист (в отличие от GPL-зависимостей внутри Go-xray).
>
> necko-xray мы **не клонировали** (недоступен); используем лишь опубликованное описание архитектуры —
> это идеи/факты, под clean-room допустимо.

## 9.2. Идеи из shoes → наша DDD-модель

### A. Типизированный декларативный конфиг вместо «stringly JSON» — контекст **Access** / **Xray Orchestration**
shoes описывает inbound строго типами через `serde` (`src/config/types/server.rs`):
```rust
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]          // ← неизвестные поля = ошибка, не молчаливый дрейф
pub struct ServerConfig {
    #[serde(flatten)] pub bind_location: BindLocation,
    pub protocol: ServerProxyConfig,    // ← enum: Vless|Vmess|Trojan|Shadowsocks|Hysteria2|...
    pub transport: Transport,           // ← enum: Tcp|Quic + Tls|Ws|Reality|Vision
    pub rules: NoneOrSome<ConfigSelection<RuleConfig>>,
    pub dns: Option<DnsConfig>, ...
}
```
**Идея для нас:** Xray управляется JSON'ом со «строковыми» полями (`protocol: "vless"`, settings как
`map`). В Rust-панели inbound-настройки моделируем **типизированными enum'ами/VO** (как у shoes), а
сериализацию в JSON-конфиг Xray держим в Anti-Corruption Layer. Инварианты протокола ловятся
компилятором, а не рантаймом Xray. → усиливает `04-domain-model` (Inbound, ProtocolSettings как VO).

Ergonomics-приёмы, которые стоит украсть: `deny_unknown_fields` (строгая валидация конфига),
`NoneOrSome`/`OneOrSome` (поле принимает одно значение или список), `ConfigSelection` (значение
инлайн ИЛИ ссылка на именованный объект — «named PEM, define once, reference everywhere»).

### B. Hot reloading как штатная фича — подтверждает наш **hot-diff**
README shoes: *«Hot reloading — apply config changes without restart»*; есть `notify` (watch файла) и
модуль `validate.rs`. Это ровно наша центральная доменная идея (`04#hot-diff`): конфиг — декларативен,
изменения применяются диффом. **Вывод:** hot-diff — не наша экзотика, а проверенный паттерн; в пути A
мы делаем его через gRPC к Xray (add/remove inbound/user без рестарта), модель `ApplyPlan` остаётся.

### C. Per-connection учёт трафика — контекст **Traffic**
`activity_tracker.rs` + `activity_tracked_stream.rs`: поток оборачивается трекером, который считает
байты по соединению. **Идея:** в пути A счётчики даёт Xray Stats API, но модель доменного события
`TrafficObserved{client, up, down, at}` и идея «обёртка-стрим считает трафик» — это чистый ориентир
для нашего Traffic-агрегата и (в пути B) прямой механизм.

### D. User lookup / аутентификация по соединению — контекст **Access**
`user_lookup.rs` — резолв клиента по credential (uuid/password) на входящем. **Идея:** в нашей модели
это `Client` + `Credential` VO; lookup-таблица «credential → client» — это read-model для быстрой
идентификации. (В пути A делает Xray; в пути B — наш.)

### E. Rule-based routing — концепт **Routing**
`rules.rs` + `config/types/rules.rs` + `ConfigSelection<RuleConfig>`: маршрутизация по IP/CIDR/маске
хоста. Совпадает с routing-правилами Xray. **Идея:** Routing моделируем как набор `Rule` VO
(match → outbound), независимо от того, кто исполняет (Xray в A, мы в B).

> 📂 Полная DDD-реконструкция архитектуры shoes — в [`shoes/`](shoes/README.md) (контексты, доменная
> модель, сквозной путь соединения, паттерны). Ниже — только выжимка идей.

### F. Handler-factory + trait-абстракция протокола — порт **data-plane** (актуально для пути B)
`tcp_server_handler_factory.rs` / `tcp_client_handler_factory.rs` / `tcp_handler.rs`: единый trait
обработчика, фабрики по протоколу. **Идея (путь B):** это и есть наш порт «прокси-ядро»: trait
`InboundHandler`/`OutboundHandler`, реализации по протоколам. На пути A нам не нужно, но это готовая
карта, если когда-нибудь заменим Go-ядро.

### G. Нативные REALITY / Vision / Hysteria2 / TUIC — актив пути B
Каталог `reality_*.rs` (полноценная реализация REALITY TLS1.3), `vision_*.rs`, `hysteria2_server.rs`,
`tuic_server.rs`, `shadow_tls_*.rs`. **Идея:** если идём в путь B — это покрывает ровно те транспорты,
что нужны панели, без написания крипто с нуля.

## 9.3. Идеи из архитектуры necko-xray (из публичного описания)

necko-xray (deep alpha, v1.0.3) декларирует расщепление ответственности:
- **xray-core** — движок трафика;
- **necko-xray (Rust)** — «мозг»: управление процессом Xray, API, логика;
- **PostgreSQL** — долговременное хранилище (users, settings, history);
- **Valkey (Redis)** — высокоскоростной кэш realtime-статистики и онлайн-пользователей.

🔑 **Сильная идея для нас — разделение горячего и холодного состояния.** 3x-ui складывает всё в один
SQLite. necko-xray выносит **realtime-метрики и online-tracking в Redis/Valkey**, а durable-данные — в
Postgres. Это снимает write-нагрузку со статистики трафика (она пишется часто) с основной БД.

**Проекция на нашу модель:**
- Контекст **Traffic** и «online users» → опциональный быстрый кэш-адаптер (Redis) за портом
  `TrafficStatsStore` / `OnlineTracker`, durable-сводки — в SQLite/Postgres за `Repository`.
- Это **адаптерное** решение: домен про Redis не знает (гексагон из `06`). Включаемо как фича для
  крупных инсталляций; на старте достаточно SQLite (наш default).
- Подтверждает наш выбор `sqlx` (SQLite default + Postgres) и общую форму пути A
  («Rust-мозг + xray-движок»).

## 9.4. Что берём сейчас (путь A) vs паркуем (путь B)

| Идея | Контекст | Путь A (сейчас) | Путь B (потом) |
|------|----------|:---:|:---:|
| Типизированный конфиг inbound (enum+serde, deny_unknown_fields) | Access / Xray Orch | ✅ берём | ✅ |
| ConfigSelection / NoneOrSome / named refs | (config-моделирование) | ✅ берём | ✅ |
| Hot-diff / hot-reload | Xray Orch | ✅ (через gRPC) | ✅ (нативно) |
| Разделение hot(Redis)/cold(SQL) состояния | Traffic / Access | ⚙️ опционально (адаптер) | ⚙️ |
| Доменное событие TrafficObserved | Traffic | ✅ модель | ✅ механизм |
| Rule VO для Routing | Routing | ✅ модель | ✅ |
| Handler-trait / фабрики протоколов | data-plane порт | ⏸ не нужно | ✅ основа |
| Нативные REALITY/Vision/Hysteria2/TUIC | data-plane | ⏸ не нужно | ✅ (берём shoes-код, MIT) |

## 9.5. Вердикт

- **Путь A** обогащается **тремя сразу применимыми идеями**: (1) типизированная модель конфига inbound
  вместо stringly-JSON, (2) подтверждённый паттерн hot-diff, (3) опциональное разделение hot/cold
  состояния (Redis для realtime-стат и online).
- **Путь B** получает конкретную основу: `shoes` (MIT, лицензионно чист для закрытого продукта)
  покрывает протоколы/транспорты и даёт готовую trait-архитектуру data-plane.
- Кодовый перенос — **только из `shoes` (MIT)** и **только если** пойдём в путь B; из 3x-ui/sing
  (GPL) и из necko-xray (лицензия неизвестна) берём **исключительно идеи**, по правилу `08`.

---
*Источники: `Vendor/shoes` @ 607ccde (MIT); публичное описание necko-xray (репозиторий недоступен на 2026-06-16). Анализ идейный, без переноса кода.*
