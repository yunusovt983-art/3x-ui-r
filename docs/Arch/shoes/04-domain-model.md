# 04 — Доменная модель

Модель shoes — это не «сущности в БД» (их нет), а **типы, через которые течёт соединение**. Разложим их
DDD-категориями: value objects (неизменяемые описания), агрегаты (узлы с инвариантами), порты (traits).

## 4.1. Value Objects (адресация)

```rust
// address.rs
enum Address { Ipv4(Ipv4Addr), Ipv6(Ipv6Addr), Hostname(String) }   // :5
struct NetLocation { address: Address, port: u16 }                   // :85
struct ResolvedLocation { location: NetLocation, resolved_addr: Option<SocketAddr> }  // :179
```
- **`NetLocation`** — каноничное «куда» (host:port), парсится с учётом IPv6-двоеточий.
- **`ResolvedLocation`** — VO с **ленивым кэшем резолва**: имя резолвится один раз (при матчинге правил
  или коннекте) и переиспользуется по всей цепочке. Инвариант: `set_resolved()` кэширует SocketAddr.
- **`NetLocationMask`** — маска для правил (CIDR для IP, subdomain-match для hostname, опц. порт).

## 4.2. Агрегат конфигурации сервера

```rust
// config/types/server.rs:157
struct ServerConfig {
    bind_location: BindLocation,                       // address | unix path
    protocol: ServerProxyConfig,                       // enum: Vless|Vmess|Trojan|Ss|Socks|Http|Tls|...
    transport: Transport,                              // Tcp|Quic|Udp
    tcp_settings: Option<TcpConfig>,
    quic_settings: Option<ServerQuicConfig>,
    rules: NoneOrSome<ConfigSelection<RuleConfig>>,    // инлайн или ссылка на группу
    dns: Option<DnsConfig>,
}
```
**Инварианты (проверяются в `validate.rs`):**
- `deny_unknown_fields` — неизвестное поле = ошибка конфига, а не молчаливый дрейф.
- REALITY private key декодируется в X25519 (`validate_reality_private_key`), short_id ≤ 16 hex.
- QUIC требует cert/key; протокол-специфичные согласованности.
- Ссылки на группы (`ConfigSelection::GroupName`) обязаны резолвиться (топологически, без циклов).

`ServerProxyConfig` — **sum type протокола**: каждый вариант несёт ровно свои настройки (Vless → user_id;
Trojan → password; Tls → набор tls/shadowtls/reality targets + inner protocol). Невалидная комбинация
полей невыразима на уровне типов.

## 4.3. Ключевые порты (traits)

### Протокольные handler'ы
```rust
// tcp/tcp_handler.rs:72
#[async_trait] trait TcpServerHandler: Send + Sync + Debug {
    async fn setup_server_stream(&self, s: Box<dyn AsyncStream>) -> io::Result<TcpServerSetupResult>;
}
// :88
#[async_trait] trait TcpClientHandler: Send + Sync + Debug {
    async fn setup_client_tcp_stream(&self, s: Box<dyn AsyncStream>, loc: ResolvedLocation)
        -> io::Result<TcpClientSetupResult>;
    fn supports_udp_over_tcp(&self) -> bool { false }
}
```
**`TcpServerSetupResult`** (`:10`) — алгебраический результат входящего handshake:
`TcpForward{remote_location, stream, proxy_selector, connection_success_response?, initial_remote_data?}`
| `BidirectionalUdp` | `MultiDirectionalUdp` | `SessionBasedUdp` | `AlreadyHandled`.
→ Handler не «делает форвард», он **возвращает намерение** — диспетчер решает, что дальше. Это близко к
доменному событию/команде.

### Исходящие коннекторы
```rust
trait SocketConnector  { async fn connect(...) -> io::Result<Box<dyn AsyncStream>>; ... }   // создать сокет (хоп 0)
trait ProxyConnector   { async fn setup_tcp_stream(stream, target) -> io::Result<TcpClientSetupResult>; ... } // обернуть протоколом
```
Разделение ответственности: **«как дотянуться до X»** (socket) vs **«обернуть поток протоколом Y до Z»** (proxy).

### Резолвер
```rust
trait Resolver: Send + Sync + Debug { fn resolve_location(&self, loc: &NetLocation) -> ResolveFuture; }  // resolver.rs:19
```
Реализации компонуются: `Timeout(Refreshing(Composite([Hickory, Caching])))`.

### Поток
```rust
trait AsyncStream: AsyncRead + AsyncWrite + AsyncPing + Unpin + Send + Sync {}   // async_stream.rs:173
```
Универсальный VO «канал байтов». Всё (TCP/TLS/WS/QUIC/crypto) — реализации; обёртки делегируют внутрь.

## 4.4. Агрегат маршрутизации

```rust
// client_proxy_selector.rs
struct ConnectRule { masks: Vec<NetLocationMask>, action: ConnectAction }       // :114
enum  ConnectAction { Allow { override_address: Option<NetLocation>, chain_group: ClientChainGroup }, Block }  // :126
struct ClientProxySelector { rules: Vec<ConnectRule>, resolve_rule_hostnames: bool, cache: Option<RoutingCache> }  // :191
```
**Поведение `judge()`** (`:283`): линейный проход по правилам, **первое совпадение выигрывает**, нет
совпадения → `Block` (неявный default-deny). LRU-кэш (cap 10000) включается при DNS-резолве или >16 правил.
**Инвариант:** порядок правил значим (priority-, не specificity-based).

## 4.5. Агрегат цепочки прокси

```rust
// client_proxy_chain.rs:79
struct ClientProxyChain {
    initial_hop: Vec<InitialHopEntry>,                  // хоп 0: пары socket+proxy
    initial_hop_next_index: AtomicU32,                  // round-robin
    subsequent_hops: Vec<Vec<Box<dyn ProxyConnector>>>, // хопы 1+: только протокол
    subsequent_next_indices: Vec<AtomicU32>,            // round-robin per hop
    udp_final_hop_indices: Vec<usize>, ...
}
enum InitialHopEntry { Direct(Box<dyn SocketConnector>), Proxy { socket, proxy } }  // :38
```
**Инварианты:**
- Хоп 0 — атомарная пара socket+proxy (выбираются вместе, чтобы не было рассинхрона).
- Балансировка — **round-robin per-hop** через `AtomicU32::fetch_add`, независимо на каждом уровне.
- UDP-способность важна **только на финальном хопе**; промежуточные всегда TCP.
- Early data от промежуточного хопа (которого не ждали) → ошибка.

## 4.6. Стек обёрток потока (декоратор) в ASCII

Каждый транспорт реализует `AsyncStream` и делегирует чтение/запись во внутренний поток:

```
   байты от клиента
        │
        ▼
   ┌──────────────────────────────────────────────┐
   │ TcpStream                   async_stream.rs   │  ← базовый AsyncStream
   ├──────────────────────────────────────────────┤
   │ ⤷ CryptoTlsStream  (← CryptoConnection)        │  TLS / REALITY терминация,
   │   rustls | reality          crypto/*           │  маршрутизация по SNI
   ├──────────────────────────────────────────────┤
   │ ⤷ VisionStream      vless/vision_stream.rs     │  XTLS-падинг → Direct(zero-copy)
   ├──────────────────────────────────────────────┤
   │ ⤷ Protocol handler  (VLESS/Trojan/VMess/...)   │  видит «чистый» поток + dest
   └──────────────────────────────────────────────┘
        InnerProtocol = Normal | VisionVless | Naive   (tls_server_handler.rs:44)
```

## 4.7. Карта «кто кого порождает»

```
YAML object ──serde──▶ Config (enum)
   Config::Server ──validate──▶ ServerConfig (агрегат)
      .protocol ──factory──▶ Box<dyn TcpServerHandler>
      .rules    ──build──▶ ClientProxySelector { Vec<ConnectRule> }
         ConnectAction::Allow.chain_group ──build──▶ ClientProxyChain
            InitialHopEntry / Box<dyn ProxyConnector>
      .dns ──build──▶ Arc<dyn Resolver>
```

Доменная суть: **декларативный конфиг компилируется в граф trait-объектов**, по которому затем течёт
каждое соединение (см. [05](05-core-domain-data-path.md)).
