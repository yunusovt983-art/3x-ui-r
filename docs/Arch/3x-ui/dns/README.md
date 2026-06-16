# DNS (miekg/dns) — DDD-исследование (резолвинг и fakedns)

> Архитектура [`miekg/dns`](https://github.com/miekg/dns) (BSD-3) — низкоуровневая DNS-библиотека
> (wire-формат, Client/Server). Для 3x-ui это фундамент **DNS-подсистемы**, которую панель настраивает:
> резолверы, правила по доменам, query-strategy, fakedns. Сам feature-слой — `xray-core/app/dns`
> (см. [xray-core](../xray-core/README.md)); miekg/dns — представитель wire-уровня в дереве зависимостей.

Источник: `../../../../Vendor/miekg-dns`, `Vendor/xray-core/app/dns`. Анализ идейный.

> ⚠️ Честно: xray для парсинга использует преимущественно `golang.org/x/net/dns/dnsmessage`, а не
> miekg/dns напрямую (miekg/dns тянется транзитивно). Но как **модель DNS-подсистемы** miekg/dns —
> отличный, явный референс (Msg/RR/Client/Server, транспорты).

## 1. Что даёт библиотека

Низкоуровневый контроль над DNS: сборка/разбор сообщений, Client (запрос), Server (свой DNS).
Философия «less is more» — никакого неявного кэша/ретраев/фолбэка; стратегию задаёт вызывающий.

```
   dns.Msg { MsgHdr, Question[], Answer[]RR, Ns[]RR, Extra[]RR, Compress }
        │  Client.Exchange(msg, "1.1.1.1:853")           Server.ListenAndServe()
        ▼                                                  │ Handler.ServeDNS(w, r)
   Client{ Net: ""|tcp|tcp-tls, TLSConfig, timeouts }      ▼ w.WriteMsg(resp)
        │ Net выбирает транспорт:                     RR (interface): A/AAAA/CNAME/
        ├ ""/udp  (512B, EDNS0 расширяет)                  TXT/MX/SRV/NS/SOA/PTR…
        ├ tcp     (2-byte length prefix, RFC7766)
        └ tcp-tls (DoT, :853)
   (DoH/DoQ — вне miekg/dns; в xray это app/dns/nameserver_{doh,quic}.go)
```

## 2. Зачем проксе настраиваемый DNS (доменный смысл)

- **Против DNS-leak**: резолвить через заданные резолверы, а не через ISP.
- **Routing-by-domain**: правилам маршрутизации нужен домен→IP; DNS встроен в выбор outbound.
- **FakeDNS**: вернуть фейковый IP, перехватить трафик по нему и роутить по домену без реального lookup
  (`app/dns/nameserver_fakedns.go`).
- **Несколько upstream** с фолбэком и geo-правилами; **query-strategy** (IPv4/IPv6/both/system).

## 3. Что настраивает панель

| Поле | Смысл |
|------|-------|
| DNS servers (адрес + протокол) | `1.1.1.1` udp / `…:853` DoT / DoH / DoQ / `localhost` / **fakedns** |
| per-domain правила | какой резолвер для каких доменов (geo, обход) |
| query strategy | `UseIP` / `UseIPv4` / `UseIPv6` / `UseSystem` |
| static hosts | переопределение `example.com → 1.2.3.4` |
| cache / serveStale | кэш ответов, отдача протухших |
| client IP (EDNS0) | прокидывать реальный IP клиента upstream (geo-ответы) |

> DDD-смысл: это поддерживающий контекст; в нашей модели — `DnsSettings{ servers: Vec<DnsServer>,
> rules, strategy, hosts, fakedns? }`, который ACL [BC-2](../xray-core/README.md) сериализует в секцию
> `dns` конфига xray. Изменение `dns` у xray — **статическая секция** ⇒ требует `Restart`
> (см. [hot-diff H5](../04-domain-model.md#hot-diff)).

## 4. Что забираем в Rust-проект

- **Типизированная `DnsSettings`** с enum транспорта резолвера (`Udp/Tcp/DoT/DoH/DoQ/FakeDns/System`)
  и query-strategy — вместо строковых полей.
- **Понимание fakedns** как механизма routing-by-domain (влияет на модель Routing и подписки).
- **Связь с hot-diff**: секция `dns` — рестартная; это инвариант, который наш `HotDiffCalculator` учитывает.
- На Rust wire-уровень даёт `hickory-dns` (резолвер + сервер, как у [shoes](../../shoes/README.md)),
  feature-слой (правила/fakedns/strategy) — наш или xray (путь A).

> miekg/dns под BSD-3 (permissive) — совместимо с AGPL. Панель DNS не исполняет (путь A) — моделирует
> конфигурацию; исполняет xray `app/dns`.
