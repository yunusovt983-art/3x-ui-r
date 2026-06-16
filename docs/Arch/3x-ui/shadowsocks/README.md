# Shadowsocks (sing) — DDD-исследование (мульти-юзер через EIH)

> Архитектура [`sing-shadowsocks`](https://github.com/SagerNet/sing-shadowsocks) (GPL-3.0) на базе
> [`sing`](https://github.com/SagerNet/sing) (GPL-3.0). Для 3x-ui интересен прежде всего
> **Shadowsocks 2022**: его мульти-юзерная модель (один inbound — много клиентов с разными PSK)
> ложится на [BC-1 Access](../03-bounded-contexts.md) ближе, чем легаси-SS с одним паролем.

Источник: `../../../../Vendor/sing-shadowsocks`, `Vendor/sing`. Анализ идейный.

## 1. Две эпохи шифров

| Семейство | Методы | KDF | Мульти-юзер |
|-----------|--------|-----|-------------|
| Легаси AEAD | `aes-128/192/256-gcm`, `chacha20-poly1305`, `xchacha20-poly1305` | MD5-based | ❌ один пароль на inbound |
| **SS2022** | `2022-blake3-aes-128-gcm`, `2022-blake3-aes-256-gcm`, `2022-blake3-chacha20-poly1305` | **BLAKE3** | ✅ через EIH + per-user uPSK |

Абстракция шифра — `Method` (`shadowsocks.go`): `DialConn`/`DialPacketConn`. Серверная сторона —
`Service` (один PSK) или **`MultiService[U]`** (SS2022, много пользователей).

## 2. Мульти-юзер SS2022: EIH (Extended Identity Headers)

```
   Сервер хранит:  iPSK (мастер)  +  uPSKHash:  blake3.Sum512(uPSK)[:16] → User
                                    uPSK[User]  (для session-ключей)

   Клиент шлёт:                          Сервер:
   ┌───────────────────────────────┐      ┌───────────────────────────────────────┐
   │ salt                          │      │ identitySubkey =                      │
   │ EIH = Enc_iPSK( hash(uPSK) )  │ ───▶ │  blake3.DeriveKey("…identity…",       │
   │ enc_session( header+payload ) │      │     iPSK ‖ salt)                      │
   └───────────────────────────────┘      │ Dec(EIH) → hash → uPSKHash[hash]=User │
                                          │ sessionKey = DeriveKey(uPSK, salt)    │
                                          │ ctx = auth.ContextWithUser(User)      │
                                          └───────────────────────────────────────┘
   ⇒ сервер опознаёт пользователя ДО расшифровки payload, по зашифрованному заголовку
```
- session-ключ: `blake3.DeriveKey("shadowsocks 2022 session subkey", uPSK ‖ salt)`.
- защита от replay: epoch (±30с) + sliding-window по packet-id (UDP).
- `MultiService.UpdateUsersWithPasswords(users, passwords)` — горячее обновление набора uPSK.

## 3. Формат паролей (важно для панели)

- **Легаси**: произвольная строка-пароль (сервер хеширует MD5).
- **SS2022**: **base64**-кодированный PSK; длина строго по шифру (16 байт для aes-128, 32 — для
  aes-256/chacha20). Сервер: `iPSK` (мастер) + список `uPSK` (по клиенту), оба base64.

> Невалидная длина PSK = ошибка. В нашей модели это VO `Ss2022Psk` с валидацией длины под выбранный
> `Method`.

## 4. Роль `sing` (общий фундамент)

`sing` даёт примитивы, переиспользуемые во всех проектах SagerNet:
- `N.TCPConnectionHandler`/`N.UDPHandler` — порты обработки соединений/пакетов;
- `M.Socksaddr` — VO сетевого адреса (IPv4/IPv6/FQDN+port), сериализация SOCKS-style;
- `M.Metadata{ Protocol, Source, Destination }` — контекст соединения;
- `buf.Buffer` — пулы буферов; `auth.ContextWithUser[T]` — проброс идентичности пользователя.

> DDD-смысл: `sing` — это, по сути, **порты и value objects data-plane** (как у [shoes](../../shoes/README.md),
> но в Go). `auth.ContextWithUser` = тот самый шов «соединение → User», на котором строится per-user учёт.

## 5. Что забираем в Rust-проект

- **Доменная модель SS-клиента двух видов**: легаси (один пароль на inbound) vs **SS2022 multi-user**
  (`Inbound::Shadowsocks{ method, server_psk, clients: Vec<{email, upsk}> }`). Для SS2022 клиент =
  per-user uPSK, что **естественно** ложится на наш агрегат `Client`.
- **VO `Ss2022Psk`** с валидацией длины под `Method`; генерация PSK (base64) как доменный сервис.
- **Идея EIH** — почему SS2022 поддерживает много клиентов на одном порту (в отличие от легаси): это
  объясняет, как панель раздаёт одному inbound много подписок.
- **Маппинг user→uPSK + «опознать до расшифровки»** — для понимания per-user учёта SS2022.

> sing-shadowsocks под **GPL-3.0** — под AGPL панели ([§08](../../08-licensing-compliance.md)) совместимо;
> исполнение в xray (`proxy/shadowsocks`, путь A) либо в Rust-ядре `shoes` (`shadowsocks_*`, путь B).
