# QUIC / Hysteria2 / TUIC — DDD-исследование (UDP-транспорты)

> Архитектура [`quic-go`](https://github.com/quic-go/quic-go) (MIT) и форка Hysteria
> [`apernet/quic-go`](https://github.com/apernet/quic-go) (MIT). Для 3x-ui это семейство
> **QUIC-based inbound'ов** — Hysteria2 и TUIC, — которые панель настраивает иначе, чем TCP-протоколы:
> ключевой параметр здесь не транспорт-security, а **bandwidth/congestion**.

Источник: `../../../../Vendor/quic-go`, `Vendor/apernet-quic-go`, `Vendor/xray-core/transport/internet/hysteria`. Анализ идейный.

## 1. Что даёт QUIC проксированию

QUIC = мультиплексированный, шифрованный (TLS 1.3 встроен), UDP-based транспорт со стримами:
- нет head-of-line blocking TCP; мультиплекс по **Connection ID**, а не 4-tuple;
- 0-RTT и connection migration (смена IP без разрыва) — устойчивость на мобильных/lossy-сетях;
- unreliable **DATAGRAM** (RFC 9221) — основа UDP-over-QUIC в TUIC.

Ключевые типы `quic-go`: `Transport` (мультиплексор одного UDP-сокета), `Listener.Accept → Conn`,
`Stream`, и `quic.Config` (`MaxIdleTimeout`, `KeepAlivePeriod`, `MaxIncomingStreams`,
`Initial/MaxStreamReceiveWindow`, `EnableDatagrams`, `Allow0RTT`).

## 2. Зачем Hysteria форкает quic-go (apernet) — Brutal CC

```
   upstream quic-go: CUBIC/Reno — реагирует на потери (back-off), «честный» к сети
        ▼ форк apernet/quic-go + xray .../hysteria/congestion/brutal
   Brutal: шлёт с ЗАДАННОЙ пользователем скоростью (up/down bps), НЕ реагируя на loss
   ┌─────────────────────────────────────────────────────────────────────┐
   │ BrutalSender(target_bps) → Pacer держит rate ≈ target               │
   │ корректирует по ACK/loss-ratio, но не делает CUBIC-style back-off   │
   └─────────────────────────────────────────────────────────────────────┘
   зачем: на throttled/censored/спутниковых линках loss-based CC «проседает»;
   Brutal даёт предсказуемую полосу ценой агрессивности
```
xray умеет переключать CC на лету: `conn.SetCongestionControl(cc)` (`hysteria/congestion/utils.go`).
Значения: `brutal` (default), `force-brutal`, `bbr`, `reno`.

## 3. Как Hysteria2 и TUIC используют QUIC

```
  Hysteria2 (HTTP/3 поверх apernet-quic-go)              TUIC v5
  ───────────────────────────────────────              ─────────────────────
  ALPN "h3"; auth по HTTP-заголовкам:                   auth по UUID+password
   Hysteria-Auth: <password>                            UDP через QUIC DATAGRAM
   Hysteria-CC-RX: <bps> (клиент объявляет down)        (EnableDatagrams)
  сервер 233 + свой CC-RX; congestion.UseBrutal(        TCP — обычные QUIC-стримы
   conn, min(up, client_down))                          ниже задержка для UDP
  TCP → QUIC-стрим (frame 0x401); UDP → session-mgr
  padding от DPI (Auth/Tcp request padding)
```

## 4. Что настраивает панель (config-шов)

Для Hysteria2/TUIC inbound админ задаёт (через xray `streamSettings`/`settings`):
| Поле | Смысл |
|------|-------|
| port / listen | UDP-порт |
| auth password (Hysteria2) / uuid+password (TUIC) | аутентификация |
| **brutalUp / brutalDown** (bps) | целевая полоса для Brutal CC |
| congestion | `brutal`/`force-brutal`/`bbr`/`reno` |
| obfs password (salamander) | обфускация от DPI (опц.) |
| maxIdleTimeout / keepAlivePeriod | `quic.Config` |
| (TUIC) udpRelayMode, congestionControl | режим UDP |

> DDD-смысл: у QUIC-протоколов главный доменный параметр — **пропускная способность/CC**, а не
> stream-security. Это новый VO в нашей модели `StreamSettings`.

## 5. Что забираем в Rust-проект

- **Типизированный вариант `Inbound::Hysteria2{ auth, brutal_up, brutal_down, congestion, obfs? }`**
  и `Inbound::Tuic{ users, udp_relay_mode, congestion }` — bandwidth как доменное значение (bps newtype).
- **Понимание Brutal** — чтобы корректно объяснять/валидировать поля (force-brutal игнорирует
  объявленную клиентом полосу).
- **DATAGRAM-флаг** как признак UDP-over-QUIC (TUIC).
- На Rust data-plane (путь B) есть `quinn` (QUIC) + реализации hysteria2/tuic в [`shoes`](../../shoes/README.md);
  на пути A исполняет xray.

> Лицензии quic-go/apernet — MIT; под AGPL панели совместимо. Панель их не линкует (путь A) — только
> моделирует параметры конфигурации.
