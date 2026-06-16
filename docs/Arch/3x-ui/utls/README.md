# uTLS — DDD-исследование (подделка TLS-fingerprint)

> Архитектура [`refraction-networking/utls`](https://github.com/refraction-networking/utls) (BSD-3) —
> форк `crypto/tls`, позволяющий маскировать TLS ClientHello под реальный браузер. Для 3x-ui это
> **одно поле настройки** — `fingerprint` (chrome/firefox/safari/…), которое панель выставляет на
> outbound/REALITY. Понимание нужно, чтобы знать набор допустимых значений и их смысл.

Источник: `../../../../Vendor/utls` + `Vendor/xray-core/transport/internet/tls/tls.go`. Анализ идейный.

## 1. Какую проблему решает

Стандартный Go `crypto/tls` шлёт **узнаваемый ClientHello** (порядок ciphers/расширений → JA3-fingerprint).
DPI блокирует целые классы инструментов по этому отпечатку ещё до завершения handshake. uTLS делает
ClientHello **неотличимым от настоящего браузера** (Chrome/Firefox/Safari/iOS) или рандомизирует его.

## 2. Ключевые абстракции

```
   ClientHelloID  ──(factory key)──▶  ClientHelloSpec  ──(apply)──▶  UConn  ──Handshake()──▶ провод
   "Chrome"/"Firefox"/                CipherSuites[],                 *crypto/tls.Conn +
   "Randomized"/"Custom"              Extensions[] (в порядке!),      перехват ClientHello
   + Version/Seed/Weights             TLSVers, GetSessionID
```

- **`UConn`** (`u_conn.go`) — обёртка над `crypto/tls.Conn`, перехватывающая ClientHello до маршалинга.
- **`ClientHelloID`** (`u_common.go`) — иммутабельный «токен личности»: какой браузер пародировать.
- **`ClientHelloSpec`** — декларативный чертёж ClientHello (ciphers + extensions **в порядке** + версии).
- **`TLSExtension`** — композируемые расширения (SNI, ALPN, KeyShare, GREASE, Padding, …). **Порядок
  значим** — по нему DPI и детектит.

## 3. Главные API и пути к spec

| API | Что делает | Файл |
|-----|------------|------|
| `UClient(conn, config, helloID)` | создать uTLS-клиент | `u_conn.go` |
| `BuildHandshakeState()` / `Handshake()` | материализовать ClientHello / выполнить рукопожатие | `u_conn.go` |
| `ApplyPreset(spec)` | применить кастомный spec | `u_parrots.go` |
| `Fingerprinter.RawClientHello(bytes)` | разобрать перехваченный ClientHello → spec | `u_fingerprinter.go` |
| `Roller.Dial(...)` | перебор отпечатков с фолбэком и мемоизацией рабочего | `u_roller.go` |

Четыре источника spec: **пресет** (парро­тинг браузера) · **fingerprinter** (по перехвату) ·
**randomized** (GREASE-рандом) · **custom** (руками собрать `Extensions`).

## 4. Пресеты (то, что панель показывает в выпадашке)

`HelloChrome_Auto`, `HelloFirefox_Auto`, `HelloSafari_Auto`, `HelloIOS_Auto`, `HelloEdge_Auto`,
`HelloAndroid_11_OkHttp`, `Hello360_Auto`, `HelloQQ_Auto`, `HelloRandomized[ALPN/NoALPN]`, плюс
версионные (`HelloChrome_133/120/...`, PQ-варианты `HelloChrome_115_PQ`). xray маппит имена в
`PresetFingerprints`/`ModernFingerprints` (`transport/internet/tls/tls.go`, `GetFingerprint(name)`).

## 5. Как используется в стеке (и где это в 3x-ui)

```
   панель: fingerprint = "chrome"
        │ GetFingerprint("chrome") → ClientHelloID
        ▼
   xray outbound / REALITY client → utls.UClient(tcp, cfg, id) → Handshake()
        ▼
   на проводе ClientHello выглядит как Chrome → DPI видит «браузер», не прокси
```
REALITY-клиент обязательно использует uTLS и **требует fingerprint с поддержкой TLS 1.3** (см.
[reality](../reality/README.md)).

## 6. Что забираем в Rust-проект

- **Enum `Fingerprint { Chrome, Firefox, Safari, Ios, Edge, Android, Randomized, … }`** — типизированное
  поле настройки вместо строки; список значений берём из пресетов uTLS (формат-факт).
- **Валидацию**: REALITY ⇒ fingerprint обязателен и TLS1.3-совместим (инвариант домена).
- Исполнение (реальная подделка ClientHello) — в xray (путь A). На Rust-стороне аналог — `rustls` +
  ECH/fingerprint-крейты или (путь B) механизм из [`shoes`](../../shoes/README.md).

> Брать можно идеи/значения/контракт; код uTLS (BSD, разрешает, но не нужен) в панель не тянем — это
> забота data-plane, а не control-plane.
