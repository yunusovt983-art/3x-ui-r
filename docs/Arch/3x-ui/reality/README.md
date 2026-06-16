# REALITY — DDD-исследование (анти-цензурный транспорт)

> Архитектура [`xtls/reality`](https://github.com/XTLS/REALITY) (MPL-2.0) — форк `crypto/tls`,
> реализующий схему маскировки REALITY. Для 3x-ui это **значение `StreamSettings`** инбаунда:
> панель не исполняет REALITY, а **конфигурирует** его и генерирует ключи/short-id. Понимание модели
> нужно, чтобы корректно типизировать настройки в нашем домене и сгенерировать конфиг/ссылку.

Источник: `../../../../Vendor/reality` + `Vendor/xray-core/transport/internet/reality`. Анализ идейный.

## 1. Какую проблему решает

Обычный TLS-сервер прокси палится по серверному fingerprint и уязвим к active-probing и атаке на
цепочку сертификатов. REALITY **«заимствует» настоящее TLS-рукопожатие чужого реального сайта**
(camouflage `dest`), аутентифицирует легитимного клиента криптографией, спрятанной в ClientHello, а на
неаутентифицированный зонд **прозрачно проксирует трафик к настоящему сайту**. Наблюдатель видит
легитимный TLS 1.3 к реальному домену — неотличимо.

## 2. Поток (сервер и клиент) в ASCII

```
  Клиент (легитимный)                     REALITY-сервер                    Camouflage dest
        │  ClientHello (SNI = serverName,         │  Server() сразу дублирует     (напр. example.com:443)
        │  X25519 keyshare, sessionId = шифр.     │   коннект к dest ───────────────────▶│
        │  {ver,timestamp,shortId})               │                                      │
        │───────────────────────────────────────▶ │  X25519 ECDH + HKDF → AuthKey        │
        │                                         │  AES-GCM расшифровка sessionId       │
        │                              ┌──────────┴───────────┐                          │
        │                       auth OK│                      │auth FAIL / probe         │
        │                              ▼                      ▼                          │
        │             свой TLS1.3 ответ            прозрачный проксинг к dest ◀──────────┤
        │◀──── зашифрованный туннель ─────         (наблюдатель видит реальный сайт)     │
```

- **Сервер**: `Server(ctx, conn, *Config)` (`reality/tls.go`). Дублирует коннект к `Dest`, в
  параллельных горутинах решает auth vs proxy.
- **Клиент** (через xray): `UClient(...)` (`xray-core/transport/internet/reality/reality.go`) —
  строит ClientHello поверх **uTLS** (см. [utls](../utls/README.md)), шифрует в sessionId
  `{version, timestamp, shortId}`, делает TLS 1.3, затем верифицирует сертификат сервера по
  `HMAC-SHA512(AuthKey, pubkey)`.

## 3. Механизм аутентификации (концептуально)

1. X25519 ECDH между приватным ключом сервера и keyshare клиента → общий секрет.
2. `HKDF(secret, ClientHello.random[:20], "REALITY")` → 32-байтный `AuthKey`.
3. Клиент шифрует `AuthKey`'ом в `sessionId` (AES-GCM, nonce = random[20:32], AAD = весь ClientHello)
   полезную нагрузку `{ClientVer[3], timestamp[4], shortId[8]}`.
4. Сервер расшифровывает и валидирует: `shortId ∈ ShortIds`, версия в `[MinClientVer, MaxClientVer]`,
   `|now − timestamp| ≤ MaxTimeDiff`. Успех → свой TLS; провал → проксинг к dest.

> DDD-смысл: это **value object `AuthClaim{version, timestamp, shortId}`** внутри рукопожатия;
> агрегат — само соединение `Conn` в одном из состояний (authenticated | proxying).

## 4. Конфиг, который выставляет панель

| Сторона | Поле | Смысл |
|---------|------|-------|
| **Сервер (inbound)** | `Dest` | camouflage-сайт `host:443` (куда проксировать probe) |
| | `ServerNames` | допустимые SNI |
| | `PrivateKey` | X25519 приватный (32 байта) |
| | `ShortIds` | список допустимых client short-id (0–16 hex) |
| | `MinClientVer`/`MaxClientVer`/`MaxTimeDiff` | гейтинг версии/времени (опц.) |
| | `Mldsa65Key`, `LimitFallback{Up,Down}` | post-quantum подпись, rate-limit фолбэка (опц.) |
| **Клиент (outbound)** | `PublicKey` | X25519 публичный сервера |
| | `ShortId` | свой short-id |
| | `ServerName` | какой SNI предъявлять |
| | `Fingerprint` | uTLS-отпечаток (`chrome`/`firefox`/…) |
| | `SpiderX` | путь начального «паука»-фолбэка |

> Для панели REALITY = генератор пары X25519 + short-id + форма для `Dest`/`ServerNames`. В нашей
> модели это `StreamSettings::Reality(RealityServerSettings)` — типизированный VO, валидируемый на входе.

## 5. Что забираем в Rust-проект

- **Типизированная модель `RealityServerSettings`/`RealityClientSettings`** (enum-вариант `StreamSettings`)
  с инвариантами: непустые `ServerNames`, `PrivateKey` декодируется в X25519, `ShortId` — hex ≤ 16.
- **Генерация ключей** (X25519 keypair, short-id) как доменный сервис панели — формат-факт, берём.
- **Понимание auth-claim** — чтобы корректно сериализовать конфиг и объяснять админу поля.
- Исполнение REALITY остаётся в xray (путь A). В пути B аналог уже есть в [`shoes`](../../shoes/README.md)
  (`reality_*`).

> Брать можно идеи/форматы/контракт (не код xtls/reality — MPL, и нам не нужен в бинаре панели).
