# 05 — Ядро домена: путь одного соединения

Сердце shoes — сквозной поток проксированного соединения. Здесь он разобран по шагам (TCP, затем UDP и TUN).

## 5.1. TCP: accept → forward

```mermaid
sequenceDiagram
    participant C as Клиент
    participant A as accept loop<br/>(tcp_server.rs)
    participant H as TcpServerHandler<br/>(напр. VLESS)
    participant S as ClientProxySelector
    participant Ch as ClientProxyChain
    participant U as Upstream

    C->>A: TCP connect
    A->>A: set_keepalive/nodelay; spawn task
    A->>H: setup_server_stream(stream)  [timeout 60s]
    H->>H: read frame, validate UUID/pwd, extract dest
    H-->>A: TcpForward{remote_location, stream, proxy_selector}
    A->>S: judge(remote_location, resolver)
    S-->>A: Allow{chain_group, remote_location} | Block
    A->>Ch: connect_tcp(remote_location, resolver)
    Ch->>U: hop0 socket.connect → (hops1+ proxy.wrap)
    Ch-->>A: client_stream (до upstream)
    A->>A: copy_bidirectional(server_stream, client_stream)
    Note over A,U: байты качаются до EOF, затем shutdown обеих сторон
```

**Шаги (с файлами):**
1. **Accept** (`tcp/tcp_server.rs:40`): `listener.accept()`, keepalive/nodelay, `tokio::spawn(process_stream)` — задача на соединение.
2. **Inbound handshake** (`tcp/tcp_server.rs:121`): `setup_server_stream` под 60-сек таймаутом. Handler протокола парсит кадр, проверяет credential (constant-time), достаёт `remote_location`, возвращает `TcpServerSetupResult`.
3. **Judge** (`client_proxy_selector.rs:283`): по `remote_location` — решение allow+chain / block (с LRU-кэшем, ленивым DNS если правило по hostname).
4. **Outbound chain** (`client_proxy_chain.rs:242`): выбрать initial hop (socket+proxy), пройти хопы; каждый `ProxyConnector` оборачивает поток предыдущего и делает свой handshake. Результат — `client_stream` до upstream.
5. **Copy** (`copy_bidirectional.rs:294`): кольцевой буфер 16 КБ, «читать максимум перед записью», ping-кадры для keepalive, кооперативный yield. При EOF одной стороны — `shutdown()` обеих.

**Пример (VLESS на :443 → example.com:80):** клиент шлёт VLESS-кадр → handler валидирует UUID, извлекает
`example.com:80` → judge выбирает цепочку (напр. «proxy-1 → direct») → chain: HTTP-CONNECT к proxy-1, затем
direct → `copy_bidirectional`.

**Тот же путь в ASCII (конвейер):**

```
 Клиент       accept loop        ServerHandler       Selector        ProxyChain       Upstream
   │ TCP connect  │                   │                  │               │               │
   │─────────────▶│ spawn task        │                  │               │               │
   │              │ setup_server_stream│ [timeout 60s]    │               │               │
   │              │──────────────────▶│ read frame,       │               │               │
   │              │                   │ validate creds,   │               │               │
   │              │  TcpForward{dest,  │ extract dest      │               │               │
   │              │◀─stream,selector}──│                  │               │               │
   │              │ judge(dest) ──────────────────────────▶│ first-match  │               │
   │              │◀─ Allow{chain} | Block ─────────────────│ rule / DENY  │               │
   │              │ connect_tcp(dest) ─────────────────────────────────────▶│ hop0 socket  │
   │              │                                          hops1+ proxy.wrap│  + handshake │──▶│
   │              │◀──────────────── client_stream ───────────────────────────│              │
   │              │ copy_bidirectional(server_stream, client_stream)          │              │
   │◀════════════════════════ байты в обе стороны до EOF ═════════════════════════════════▶│
```

> Транспорт (TLS/REALITY/Vision) при необходимости вклинивается **между accept и handshake** —
> см. стек-декоратор в [04 §4.6](04-domain-model.md#46-стек-обёрток-потока-декоратор-в-ascii) и §5.2 ниже.

## 5.2. Транспорт как декоратор (что происходит «внутри stream»)

Для TLS-протоколов между accept и protocol-handshake вклинивается транспортный слой:

```
TcpStream
  └─ TlsServerHandler: read ClientHello → SNI-routing → rustls handshake
       └─ CryptoTlsStream (обёртка AsyncStream поверх CryptoConnection)
            └─ InnerProtocol:
                 • Normal      → обычный TcpServerHandler (VLESS/Trojan/...)
                 • VisionVless → VisionStream (XTLS-падинг) → VLESS
                 • Naive       → HTTP/2 NaiveProxy
```
- **SNI-маршрутизация** (`tls_server_handler.rs:105`): по Server Name выбирается target (Tls / ShadowTls / Reality).
- **REALITY** (`reality/reality_server_handler.rs`): сразу коннектится к camouflage-`dest`, форвардит ClientHello, **параллельно** валидирует auth (ECDH+HKDF+AES-GCM по short_id/timestamp). Успех → строит REALITY-ответ под структуру dest и отдаёт inner-handler'у; провал → прозрачно форвардит на dest (timing-неотличимо).
- **Vision** (`vless/vision_stream.rs`): три режима (PaddingTls / Tls / Direct). Пока не виден ApplicationData — падит трафик под TLS; увидев — переключается в **Direct (zero-copy)**, убирая overhead. Команды потока: CONTINUE/END/DIRECT.

## 5.3. UDP: мультиплексирование сессий

UDP — не стрим, а дискретные сообщения с маршрутизацией per-destination.

- `TcpServerSetupResult` для UDP-протоколов возвращает `BidirectionalUdp` / `MultiDirectionalUdp` / `SessionBasedUdp`.
- **`UdpRouter`** (`routing/udp_router.rs`) мультиплексирует: читает пакеты (с destination или session_id), на каждую уникальную цель создаёт сессию (через тот же `judge()`), гоняет сообщения в обе стороны.
- Оптимизации: `DelayQueue` для O(1) истечения сессий, пулы буферов под backpressure, work-queues вместо итерации по сессиям.
- `ServerStream` enum: `Targeted` (SOCKS5/SS UoT) либо `Session` (XUDP для VLESS/VMess).

**Отличие от TCP:** нет блокирующего handshake — UDP-handler'ы возвращаются сразу, состояние живёт в роутере.

## 5.4. TUN/VPN: L3 → соединения

```
TUN fd ──IP пакеты──▶ TcpStackDirect (OS-поток, smoltcp, sync)
                          │  TCP: 3-way handshake в стеке → TcpConnectionControl (ring-буферы + wakers)
                          ├──new TCP conn──▶ tokio-задача ──▶ общий inbound-путь (judge → chain → copy)
                          └──UDP пакеты──▶ TunUdpManager (сессии per local-addr → per-destination задачи)
```
- **`TcpStackDirect`** (`tun/tcp_stack_direct.rs:119`): отдельный OS-поток крутит smoltcp; общается с async-частью через каналы (`tcp_conn_tx`, `udp_*`).
- **`TcpConnectionControl`** (`tun/tcp_conn.rs:21`): на соединение — send/recv ring-буферы, wakers (будить tokio при наличии данных/места), state machine (Normal→Close→Closing→Closed).
- Платформы: Linux (создаёт устройство), Android (FD от `VpnService`), iOS/macOS (FD от `NEPacketTunnelProvider`).

## 5.5. Сухой остаток

Ядро домена = **единый конвейер** `accept → (transport unwrap) → protocol handshake → judge → chain
connect → copy`. Все варианты (протоколы, транспорты, TCP/UDP/TUN) вливаются в этот конвейер через
trait-порты. Именно эта инвариантная «форма потока» — то, что стоит держать в голове при оценке shoes как
движка и при проектировании нашего data-plane (путь B).
