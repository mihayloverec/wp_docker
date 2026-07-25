# Отправка почты (SMTP без плагина)

🌐 **Язык / Language:** [Русский](#русский) · [English](#english)

---

<a name="русский"></a>

# 🇷🇺 Русский

Стек отправляет письма **без плагина** WordPress. Почта идёт по цепочке:

```
wp_mail()  →  PHP mail()  →  /usr/local/bin/wp-sendmail  →  msmtp  →  ваш SMTP-релей
```

`sendmail_path` в [`php/php.ini`](php/php.ini) указывает на скрипт-обёртку
[`mail/wp-sendmail.sh`](mail/wp-sendmail.sh), который вызывает `msmtp`. Всё
настраивается **только переменными окружения** из `.env` — секретов на диске нет,
пароль не виден в списке процессов (читается из env через `passwordeval`).

Работает и в веб-контейнере, и в `wp-cron` — поэтому письма, которые шлёт крон
(заказы WooCommerce, уведомления), тоже уходят.

## Быстрая настройка

В `.env` заполните блок SMTP:

```ini
SMTP_HOST=smtp-relay.brevo.com   # хост вашего SMTP-провайдера
SMTP_PORT=587                    # 587 = STARTTLS, 465 = implicit TLS
SMTP_USER=you@example.com        # логин SMTP
SMTP_PASS=your_smtp_password     # пароль / API-ключ
SMTP_FROM=wordpress@ваш-домен.ru  # адрес отправителя (под ваш домен/SPF/DKIM)
# Обычно менять не нужно:
SMTP_AUTH=on
SMTP_TLS=on
SMTP_STARTTLS=on
```

Примените:

```bash
docker compose up -d wordpress wp-cron
```

> **Порт 465 (implicit TLS)** — поставьте `SMTP_PORT=465` и `SMTP_STARTTLS=off`.
> `./verify.sh` считает ошибкой комбинацию `465` + `SMTP_STARTTLS=on` — это
> самая частая ошибка настройки SMTP.

> **`SMTP_FROM` — главный адрес.** Обёртка передаёт msmtp `--from` и
> намеренно **не** использует `--read-envelope-from`: envelope-sender должен
> быть адресом, который разрешил ваш релей и который покрыт вашими SPF/DKIM.
> Свой заголовок `From:` WordPress по умолчанию ставит как
> `wordpress@<домен сайта>`, и релеи вроде Postmark/SendGrid/Brevo
> отвергают его как неподтверждённого отправителя.

## Если почта не нужна (локалка/дев)

Оставьте `SMTP_HOST` **пустым** — обёртка отбрасывает письма и не роняет
`mail()`. Это дефолт для локальной разработки.

> ⚠️ **На боевом сайте пустой `SMTP_HOST` — это тихая потеря писем.**
> `mail()` возвращает успех, `wp_mail()` тоже, поэтому WordPress считает
> письмо отправленным и никто об этом не сообщит: ни ошибки, ни статуса.
> Заказы и сбросы пароля просто исчезают. Поэтому обёртка **громко пишет
> в лог** на каждое отброшенное письмо:
>
> ```
> [wp-sendmail] SMTP_HOST is not set — message DROPPED (mail disabled).
> ```
>
> А `./verify.sh` предупреждает, если `SMTP_HOST` пуст при
> `WP_ENVIRONMENT_TYPE=production`.

## Примеры провайдеров

| Провайдер | Хост | Порт | STARTTLS | Логин |
|-----------|------|:----:|:--------:|-------|
| Brevo (Sendinblue) | `smtp-relay.brevo.com` | 587 | on | e-mail аккаунта |
| Postmark | `smtp.postmarkapp.com` | 587 | on | server token |
| Mailgun | `smtp.mailgun.org` | 587 | on | SMTP-логин |
| SendGrid | `smtp.sendgrid.net` | 587 | on | `apikey` |
| Gmail / Workspace | `smtp.gmail.com` | 587 | on | e-mail + **App Password** |
| Yandex 360 | `smtp.yandex.ru` | 465 | off | e-mail |

> Для нормальной доставки настройте у провайдера/DNS записи **SPF** и **DKIM**
> для домена из `SMTP_FROM`, иначе письма уйдут в спам.

## Проверка

После установки WordPress отправьте тестовое письмо через wp-cli:

```bash
docker compose exec -u www-data wordpress \
  wp eval 'wp_mail("you@example.com","Test","Работает!") ? print("OK\n") : print("FAIL\n");'
```

Диагностика доставки. Обёртка запускает msmtp с `--logfile=/dev/stderr`,
поэтому в логе контейнера видна **каждая** попытка отправки — и успешная,
и неудачная (без этого «в логе тихо» невозможно было отличить «почта
работает» от «почта уходит в никуда»):

```bash
docker compose logs --tail=50 wordpress
```

Прямой тест обёртки (в обход WordPress):

```bash
docker compose exec -T wordpress sh -c \
  'printf "To: you@example.com\nSubject: test\n\nhello\n" | /usr/local/bin/wp-sendmail; echo "exit=$?"'
```

## Как это устроено

| Компонент | Роль |
|-----------|------|
| [`mail/wp-sendmail.sh`](mail/wp-sendmail.sh) | Обёртка: собирает аргументы `msmtp` из `SMTP_*`; пустой `SMTP_HOST` = drop + запись в лог; `--logfile=/dev/stderr` |
| [`php/php.ini`](php/php.ini) | `sendmail_path = "/usr/local/bin/wp-sendmail"` — **обязателен в каждом профиле** php.ini, иначе PHP уйдёт на несуществующий `/usr/sbin/sendmail` |
| [`Dockerfile`](Dockerfile) | Ставит `msmtp` + `ca-certificates`, копирует обёртку в образ |
| [`docker-compose.yml`](docker-compose.yml) | Anchor `x-smtp-env` пробрасывает `SMTP_*` в `wordpress` и `wp-cron` |

## Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| В логе `message DROPPED (mail disabled)` | `SMTP_HOST` пуст | Заполните SMTP-блок в `.env`, перезапустите |
| Получатель отверг отправителя (`sender not verified`) | `SMTP_FROM` не подтверждён у релея | Укажите в `SMTP_FROM` адрес, разрешённый провайдером |
| `authentication failed` | Неверный логин/пароль | Проверьте `SMTP_USER`/`SMTP_PASS` (у SendGrid логин = `apikey`) |
| `TLS handshake failed` на 465 | Порт 465 без implicit TLS | `SMTP_PORT=465` + `SMTP_STARTTLS=off` |
| Письма в спам | Нет SPF/DKIM | Настройте DNS-записи под домен из `SMTP_FROM` |
| `cannot use a network` / timeout | Провайдер блокирует порт | Смените порт (587↔465) или провайдера |

---

<a name="english"></a>

# 🇬🇧 English

The stack sends email **without a WordPress plugin**. Mail flows through:

```
wp_mail()  →  PHP mail()  →  /usr/local/bin/wp-sendmail  →  msmtp  →  your SMTP relay
```

`sendmail_path` in [`php/php.ini`](php/php.ini) points at the shim
[`mail/wp-sendmail.sh`](mail/wp-sendmail.sh), which calls `msmtp`. Everything is
configured **only via environment variables** from `.env` — no on-disk secrets, and
the password never appears in the process list (read from env via `passwordeval`).

It works in both the web container and `wp-cron`, so cron-sent mail (WooCommerce
order emails, notifications) is delivered too.

## Quick setup

Fill the SMTP block in `.env`:

```ini
SMTP_HOST=smtp-relay.brevo.com   # your SMTP provider host
SMTP_PORT=587                    # 587 = STARTTLS, 465 = implicit TLS
SMTP_USER=you@example.com        # SMTP login
SMTP_PASS=your_smtp_password     # password / API key
SMTP_FROM=wordpress@your-domain.org  # sender address (match your domain SPF/DKIM)
# Usually no need to change:
SMTP_AUTH=on
SMTP_TLS=on
SMTP_STARTTLS=on
```

Apply:

```bash
docker compose up -d wordpress wp-cron
```

> **Port 465 (implicit TLS)** — set `SMTP_PORT=465` and `SMTP_STARTTLS=off`.
> `./verify.sh` treats `465` + `SMTP_STARTTLS=on` as an error — it is the
> single most common SMTP misconfiguration.

> **`SMTP_FROM` is authoritative.** The shim passes `--from` to msmtp and
> deliberately does **not** use `--read-envelope-from`: the envelope sender
> must be the address your relay authorised and your SPF/DKIM records cover.
> WordPress's own `From:` header defaults to `wordpress@<site-domain>`, which
> relays like Postmark/SendGrid/Brevo reject as an unverified sender.

## When you don't need mail (local/dev)

Leave `SMTP_HOST` **empty** — the shim drops messages without failing
`mail()`. This is the default for local development.

> ⚠️ **On a production site an empty `SMTP_HOST` means silent mail loss.**
> `mail()` returns success and so does `wp_mail()`, so WordPress believes the
> message was sent and nothing anywhere will flag it — orders and password
> resets simply vanish. That is why the shim **logs loudly** for every
> dropped message:
>
> ```
> [wp-sendmail] SMTP_HOST is not set — message DROPPED (mail disabled).
> ```
>
> And `./verify.sh` warns when `SMTP_HOST` is empty while
> `WP_ENVIRONMENT_TYPE=production`.

## Provider examples

| Provider | Host | Port | STARTTLS | Login |
|----------|------|:----:|:--------:|-------|
| Brevo (Sendinblue) | `smtp-relay.brevo.com` | 587 | on | account e-mail |
| Postmark | `smtp.postmarkapp.com` | 587 | on | server token |
| Mailgun | `smtp.mailgun.org` | 587 | on | SMTP login |
| SendGrid | `smtp.sendgrid.net` | 587 | on | `apikey` |
| Gmail / Workspace | `smtp.gmail.com` | 587 | on | e-mail + **App Password** |
| Yandex 360 | `smtp.yandex.ru` | 465 | off | e-mail |

> For good deliverability, configure **SPF** and **DKIM** DNS records for the domain
> in `SMTP_FROM`, otherwise mail lands in spam.

## Verify

After the WordPress install, send a test via wp-cli:

```bash
docker compose exec -u www-data wordpress \
  wp eval 'wp_mail("you@example.com","Test","It works!") ? print("OK\n") : print("FAIL\n");'
```

Delivery diagnostics. The shim runs msmtp with `--logfile=/dev/stderr`, so
the container log shows **every** attempt, successful or not (without it, "the
log is quiet" could not be distinguished from "mail works"):

```bash
docker compose logs --tail=50 wordpress
```

Test the shim directly (bypassing WordPress):

```bash
docker compose exec -T wordpress sh -c \
  'printf "To: you@example.com\nSubject: test\n\nhello\n" | /usr/local/bin/wp-sendmail; echo "exit=$?"'
```

## How it works

| Component | Role |
|-----------|------|
| [`mail/wp-sendmail.sh`](mail/wp-sendmail.sh) | Shim: builds `msmtp` args from `SMTP_*`; empty `SMTP_HOST` = drop + log line; `--logfile=/dev/stderr` |
| [`php/php.ini`](php/php.ini) | `sendmail_path = "/usr/local/bin/wp-sendmail"` — **required in every** php.ini profile, or PHP falls back to a non-existent `/usr/sbin/sendmail` |
| [`Dockerfile`](Dockerfile) | Installs `msmtp` + `ca-certificates`, copies the shim into the image |
| [`docker-compose.yml`](docker-compose.yml) | `x-smtp-env` anchor injects `SMTP_*` into `wordpress` and `wp-cron` |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Log shows `message DROPPED (mail disabled)` | `SMTP_HOST` empty | Fill the SMTP block in `.env`, restart |
| Relay rejects the sender (`sender not verified`) | `SMTP_FROM` not authorised at the relay | Set `SMTP_FROM` to an address the provider allows |
| `authentication failed` | Wrong credentials | Check `SMTP_USER`/`SMTP_PASS` (SendGrid login = `apikey`) |
| `TLS handshake failed` on 465 | Port 465 without implicit TLS | `SMTP_PORT=465` + `SMTP_STARTTLS=off` |
| Mail goes to spam | Missing SPF/DKIM | Add DNS records for the `SMTP_FROM` domain |
| `cannot use a network` / timeout | Provider blocks the port | Switch port (587↔465) or provider |
