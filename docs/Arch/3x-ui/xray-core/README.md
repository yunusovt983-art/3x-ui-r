# xray-core — DDD-исследование (движок за ACL контекста BC-2)

> Архитектура [`xtls/xray-core`](https://github.com/XTLS/Xray-core) (MPL-2.0) сквозь призму DDD.
> Это **движок data-plane**, которым управляет панель. Для 3x-ui он живёт за Anti-Corruption Layer
> контекста [BC-2 Xray Orchestration](../03-bounded-contexts.md). Понимание его модели и **gRPC-API —
> это и есть контракт**, который наша Rust-панель должна знать (и только его, не внутренности).

Источник: `../../../../Vendor/xray-core` @ `0b5b87a`. Анализ идейный (см. [clean-room](../../08-licensing-compliance.md)).

## 1. Что это и зачем панели

xray-core принимает входящие соединения (inbounds), по правилам маршрутизации выбирает исходящие
(outbounds), терминирует протоколы (VLESS/VMess/Trojan/SS/...) и транспорты (TLS/REALITY/gRPC/WS/...).
Панель **не передаёт трафик** — она лишь конфигурирует xray и читает с него статистику. Вся ценность
3x-ui построена вокруг двух швов xray: **gRPC command API** (горячее управление) и **stats counters**
(учёт трафика). Их и разбираем в первую очередь.

## 2. Рантайм-модель: Instance + Features

```
   core.Config (protobuf)
        │ core.New(config)
        ▼
   ┌──────────────────────────────────────────────────────────┐
   │ core.Instance   (core/xray.go)                             │
   │  реестр Feature'ов с DI через рефлексию:                   │
   │   RequireFeatures / AddFeature / GetFeature                │
   │  ┌────────────┬────────────┬───────────┬────────────────┐ │
   │  │ Inbound    │ Outbound   │ Router +  │ Stats Manager  │ │
   │  │ Manager    │ Manager    │ Dispatcher│ DNS · Policy   │ │
   │  └────────────┴────────────┴───────────┴────────────────┘ │
   │  .Start() поднимает все Feature; .Close() гасит            │
   └──────────────────────────────────────────────────────────┘
```

- **`Instance`** (`core/xray.go`) — корневой контейнер и менеджер жизненного цикла: `New(*Config)` →
  `Start()` → `Close()`.
- **`Feature`** (`features/feature.go`) = `HasType + Runnable(Start/Close)`. Резолвятся через
  рефлексию (`RequireFeatures(callback)` — DI по типам параметров). Это **порты ядра**:
  `features/inbound`, `features/outbound`, `features/routing` (Router+Dispatcher),
  `features/stats`, `features/dns`, `features/policy`.

> DDD-смысл: Instance — это **composition root**; Feature-интерфейсы — порты. xray внутри уже
> гексагонален. Нам это даёт точку опоры: мы общаемся с этими портами **снаружи**, через gRPC.

## 3. Три плана кода (важно не путать слои)

```
   app/        прикладные сервисы-Feature       proxy/      протоколы            transport/
   ─────────   ──────────────────────────       ───────     ──────────────       ─────────────
   dispatcher  маршрутизация + учёт трафика      vless       Inbound/Outbound     internet/ (tcp,udp,
   proxyman    жизненный цикл handler'ов         vmess        + UserManager        unix, dialer)
   stats       счётчики, online-карты            trojan      (AddUser/RemoveUser) internet/tls
   router      выбор outbound по правилам        shadowsocks                      internet/reality
   dns/policy  резолвинг / лимиты уровня         freedom...                       grpc/ws/httpupgrade
   commander   gRPC-сервер (точка API)
```

- **Handler** (proxyman) = жизненный цикл + обёртка над **Proxy** (протокол) + **Transport** (провод).
- **Proxy** реализует `Inbound{Process(...)}` / `Outbound{Process(...)}`; если протокол с аккаунтами —
  ещё и `UserManager{AddUser/RemoveUser/GetUser/GetUsers}` (`proxy/proxy.go`). Это то, что под капотом
  делает hot add/remove клиента.
- **Transport** — провод и security (TLS/REALITY — см. соседние [reality](../reality/README.md) и [utls](../utls/README.md)).

## 4. gRPC command API — КОНТРАКТ для панели

Это самый важный для нас раздел: ровно эти RPC использует 3x-ui для «горячего» управления.

```
   ┌───────────────────── app/commander (gRPC) ─────────────────────┐
   │ HandlerService            StatsService          RoutingService  │
   │ (proxyman/command)        (stats/command)       (router/command)│
   │  AddInbound               GetStats              AddRule          │
   │  RemoveInbound            QueryStats            RemoveRule       │
   │  AlterInbound  ←──┐       GetStatsOnline        ListRule         │
   │   ├ AddUserOp     │ hot   GetStatsOnlineIpList  TestRoute        │
   │   └ RemoveUserOp  │ user  GetAllOnlineUsers     SubscribeRouting │
   │  ListInbounds     │ mgmt  GetUsersStats         GetBalancerInfo  │
   │  GetInboundUsers ─┘       GetSysStats           OverrideBalancer │
   │  Add/Remove/ListOutbound                                         │
   └─────────────────────────────────────────────────────────────────┘
```

| Сервис | Что даёт панели | Где |
|--------|------------------|-----|
| **HandlerService** | Горячо добавить/убрать inbound; **добавить/убрать клиента** (`AlterInbound` + `AddUserOperation`/`RemoveUserOperation`); список inbounds; пользователи и их число | `app/proxyman/command` |
| **StatsService** | Прочитать счётчик (`GetStats`), все по паттерну (`QueryStats`), online-IP, online-пользователи, агрегированную статистику (`GetUsersStats`), системные метрики (`GetSysStats`) | `app/stats/command` |
| **RoutingService** | Добавить/убрать/список правил, тест маршрута, подписка на решения, балансировщики | `app/router/command` |

> DDD-смысл: это **Published Language** xray. В нашей модели BC-2 порт `XrayController` отображается
> 1:1 на эти RPC. `AlterInbound(AddUserOperation)` — это исполнение нашего намерения «завести клиента».
> Hot-diff ([04 §4.6](../04-domain-model.md#hot-diff)) выбирает между этими вызовами и полным рестартом.

## 5. Учёт трафика — как панель читает потребление

Счётчики именуются строкой-путём; диспетчер оборачивает поток `SizeStatWriter`'ом:

```
   user>>>{email}>>>traffic>>>uplink      ← per-user upload
   user>>>{email}>>>traffic>>>downlink    ← per-user download
   user>>>{email}>>>online                ← online-карта IP
   inbound>>>{tag}>>>traffic>>>uplink     ← per-inbound (если включено в policy)
   outbound>>>{tag}>>>traffic>>>downlink
```

- Регистрация — в `app/dispatcher/default.go` (`getLink()`), под флагами `policy.Stats.User*`.
- Чтение — `StatsService.QueryStats("user>>>")` или `GetUsersStats(include_traffic=true)`; панель парсит
  суффиксы имён. Online — через online-карты (`>>>online`).

> DDD-смысл: это сырьё для нашего контекста [BC-4 Traffic Accounting](../03-bounded-contexts.md).
> Доменное событие `TrafficObserved{email, up, down}` рождается из периодического `QueryStats`.

## 6. Конфиг: JSON → protobuf → Instance

```
   JSON (infra/conf/*)  ──parse──▶  core.Config (protobuf)  ──core.New──▶  Instance ──Start()──▶ работает
   секции: inbounds, outbounds, routing, dns, policy, stats, api, log, transport
```
- `infra/conf/*` — человекочитаемый JSON-формат; `core/config.go` (`LoadConfig`) → `core.Config`.
- `InboundHandlerConfig{tag, receiver_settings, proxy_settings}` (`TypedMessage` — протокол-агностично).

> DDD-смысл: **этот JSON — то, что не должно протекать в наш домен**. ACL BC-2 строит его из
> типизированных агрегатов `Inbound`/`Client` ([04](../04-domain-model.md)) и держит формат за `XrayConfigBuilder`.

## 7. Что забираем в наш Rust-проект

- **Контракт gRPC API как порт `XrayController`** — отображаем RPC HandlerService/StatsService/Routing
  1:1 на методы порта (через `tonic`). Это единственное, что наш домен «знает» о xray. (idea/контракт — брать можно)
- **Схему имён счётчиков** (`user>>>email>>>traffic>>>{up,down}`) — это формат-факт совместимости,
  парсим его в адаптере Traffic.
- **Идею Feature-портов** — подтверждает наш гексагон: но у нас порты — это БД/Telegram/Xray, а не
  внутренности ядра.
- **Понимание `AlterInbound`+UserOperation** — основа реализации hot add/remove client без рестарта.

> Что НЕ делаем: не тащим Go-код xray в бинарь панели, не реплицируем `infra/conf`. xray остаётся
> отдельным процессом за gRPC ([08 §8.3](../../08-licensing-compliance.md)).
