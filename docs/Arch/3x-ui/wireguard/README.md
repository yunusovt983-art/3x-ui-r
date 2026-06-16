# WireGuard — DDD-исследование (inbound на ключах, не на аккаунтах)

> Архитектура [`wireguard-go`](https://github.com/WireGuard/wireguard-go) (MIT) — userspace-реализация
> WireGuard. Для 3x-ui это **отдельный тип inbound/outbound** со своей моделью идентичности: клиент —
> это **peer с публичным ключом**, а не аккаунт с UUID/паролем. Это ломает привычную модель
> [BC-1 Access](../03-bounded-contexts.md) и требует отдельного агрегата.

Источник: `../../../../Vendor/wireguard-go`. Анализ идейный.

## 1. Чем WireGuard принципиально отличается

Это VPN на Noise-протоколе (`Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`). Сущности:
- **Device** — интерфейс с долгим **приватным ключом** + listen-порт + MTU.
- **Peer** — удалённая сторона, идентифицируемая **публичным ключом**; у каждого свой
  `allowed_ips`, опц. `preshared_key`, `endpoint`, `persistent_keepalive`.
- Идентичность = криптоключ, не логин. Шифрование ChaCha20-Poly1305 после Noise-рукопожатия.

```
   ┌─────────────────────── Device (◆ агрегат) ─────────────────────µ────┐
   │ private_key, listen_port, mtu                                       │
   │  keyMap: public_key → Peer                                          │
   │  ┌──────────── Peer ─────────µ───┐  ┌──────────── Peer ────µ──────┐ │
   │  │ public_key (identity)         │  │ public_key                  │ │
   │  │ allowed_ips [CIDR…] (trie)    │  │ allowed_ips                 │ │
   │  │ preshared_key? endpoint?      │  │ preshared_key?              │ │
   │  │ persistent_keepalive          │  │ keepalive                   │ │
   │  │ txBytes/rxBytes, lastHandshake│  │ txBytes/rxBytes             │ │
   │  └───────────────────────────────┘  └─────────────────────────────┘ │
   └─────────────────────────────────────────────────────────────────────┘
   AllowedIPs — longest-prefix trie: пакет с src-IP вне allowed_ips peer'а отбрасывается
```

## 2. Конфигурация: UAPI (текстовый протокол set/get)

Всё управление идёт через `IpcSetOperation` текстом (`device/uapi.go`):
```
set=1
private_key=<64hex>            # ключ устройства
listen_port=51820
public_key=<64hex>             # ← начинает блок нового peer (= наш «клиент»)
preshared_key=<64hex>          # опц.
endpoint=1.2.3.4:51820         # опц. (на сервере приходит от клиента)
allowed_ip=10.0.0.2/32         # повторяемо; '-'<cidr> = убрать
persistent_keepalive_interval=25
remove=true                    # удалить peer
```

> DDD-смысл: добавить «клиента» = `public_key=` + `allowed_ip=` через UAPI. Это **порт**
> `WireGuardController` (текстовый set/get), отличный от gRPC xray для VLESS/VMess.

## 3. Доменная модель для панели (важное расхождение)

| Аспект | VLESS/VMess (BC-1) | WireGuard |
|--------|--------------------|-----------|
| Идентичность клиента | UUID / email | **публичный ключ** |
| Учёт трафика | счётчик `user>>>email>>>…` | `Peer.txBytes/rxBytes` (per-peer) |
| Лимит по email/IP | да | **нет привычного** (идентичность = ключ; IP = allowed_ips) |
| Хэндшейк | неявный | явный Noise; есть `lastHandshake` (≈ «онлайн») |

> Следствие для нашей модели: для WG нужен **отдельный вариант агрегата** —
> `Inbound::WireGuard{ private_key, port, mtu, peers: Vec<WgPeer{ pubkey, allowed_ips, psk?, keepalive }> }`.
> «Online» определяем по `lastHandshake` (свежее N сек), трафик — из per-peer счётчиков, а не из
> stats-API xray. Email/quota-лимиты к WG-пирам применимы лишь косвенно.

## 4. Что забираем в Rust-проект

- **Отдельный агрегат `WireGuardInbound`/`WgPeer`** с идентичностью по публичному ключу — не натягивать
  модель VLESS-клиента на WG.
- **Маппинг «клиент → peer»**: добавление клиента = генерация/приём пары ключей + `allowed_ips`.
- **Источник «online»/трафика** для WG — `lastHandshake` + per-peer байты (адаптер, отдельный от
  xray Stats API).
- **Формат UAPI** как контракт порта управления WG (если используем wireguard-go/wireguard-rs).
- Исполнение — в xray (`proxy/wireguard`, путь A) либо в Rust-ядре (`boringtun`/`wireguard-rs`, путь B).

> Под AGPL ([§08](../../08-licensing-compliance.md)) wireguard-go (MIT) можно и переиспользовать; на Rust
> естественнее `boringtun` (BSD) или `wireguard-rs`.
