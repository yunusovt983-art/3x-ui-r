# telego — DDD-исследование (Telegram-бот, контекст BC-8)

> Архитектура [`mymmrac/telego`](https://github.com/mymmrac/telego) (MIT) — типизированная обёртка над
> Telegram Bot API. Для 3x-ui это движок контекста [BC-8 Notification](../03-bounded-contexts.md):
> приём админских команд, меню на inline-клавиатурах, push-уведомления. На Rust ему соответствует
> `teloxide` — поэтому забираем **паттерны интеграции**, не код.

Источник: `../../../../Vendor/telego`. Анализ идейный.

## 1. Что это и роль в 3x-ui

Тонкий типобезопасный клиент Telegram Bot API: `types.go`/`methods.go` сгенерированы 1:1 с объектами/
методами Telegram. Поверх — фреймворк хендлеров (`telegohandler`) и билдеры (`telegoutil`). 3x-ui
использует это как **второй канал управления панелью** (наряду с Web-UI) и канал уведомлений о событиях
домена.

## 2. Архитектура и поток обновлений

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │ Bot (bot.go)  NewBot(token, opts…)  — типизированный клиент Bot API │
   └───────────────┬─────────────────────────────────────────────────────┘
       приём обновлений ──► <-chan Update
        ├─ UpdatesViaLongPolling(ctx)   (GetUpdates в цикле, offset по UpdateID)
        └─ UpdatesViaWebhook(...)        (POST от Telegram, проверка secret-token)
                         │
                         ▼
   ┌────────────────── telegohandler.BotHandler ─────────────────────────┐
   │  Use(middleware…)            ← auth админа, логирование, rate-limit │
   │  HandleMessage(h, Command…)  ← /start /status /add …                │
   │  HandleCallbackQuery(h, …)   ← нажатия inline-кнопок (menu:users)   │
   │  Group(pred…) + per-group Use   диспетч: первый предикат выигрывает │
   └─────────────────────────────────────────────────────────────────────┘
                         │ ctx.Bot().SendMessage / EditMessageText
                         ▼  inline / reply keyboard (telegoutil)
                     Telegram
```

- **`Bot`** (`bot.go`): `NewBot(token, opts)`; опции — logger, health-check (`GetMe`), HTTP-клиент
  (fasthttp по умолчанию), кастомный API-сервер.
- **Два способа приёма**: long polling vs webhook — оба отдают `<-chan Update`.
- **`telegohandler`**: `BotHandler` диспетчит по предикатам (`CommandEqual`, `CallbackDataEqual`,
  `TextPrefix`, логические `And/Or/Not`), поддерживает middleware (`Use`) и группы.
- **`telegoutil`**: билдеры `Message`, `InlineKeyboard`/`InlineKeyboardButton().WithCallbackData(...)`,
  `ID(chatID)`, `EditMessageText`.

## 3. DDD-смысл и швы интеграции

| Элемент telego | Роль в BC-8 |
|----------------|-------------|
| `Update` (channel) | входящий поток команд/коллбэков — источник use-case'ов бота |
| Predicate (`CommandEqual`) | маршрутизация намерений админа на хендлеры |
| Middleware (`Use`) | **авторизация админа по chat_id** (whitelist) — до хендлера |
| `SendMessage` / push | доставка `DomainEvent` ([04 §4.8](../04-domain-model.md)) в Telegram |
| inline keyboard + `CallbackData` | навигация по меню как машина состояний (state в внешней БД) |

> Бот — это **адаптер** (driving + driven): входящие команды → сценарии приложения; исходящие
> уведомления — подписчик на доменные события. Домен про Telegram не знает.

## 4. Что забираем в Rust-проект (`teloxide`)

- **Паттерн «predicate-маршрутизация + middleware-авторизация»** — у `teloxide` это `dptree`-фильтры и
  `filter_command`; авторизация админа по `chat_id` — middleware-узел.
- **Меню как inline-клавиатуры + callback-data префиксы** (`menu:users` / `menu:config`) — машина
  состояний меню; состояние диалога — в нашем хранилище (а не в либе; telego его тоже не хранит).
- **Разделение каналов**: входящие команды (long polling/webhook) и исходящие push — независимы;
  push шлём из подписчика на `DomainEvent`.
- **Health-check при старте** (`GetMe`) — переносим как проверку валидности токена.

> telego (Go) на Rust **не используется** — берём только архитектурные паттерны; реализация на
> `teloxide` (см. [07](../../07-rust-ecosystem-survey.md)). Лицензия telego MIT, но код Go нам не нужен.
