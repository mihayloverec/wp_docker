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
SMTP_FROM=wordpress@example.com  # адрес отправителя (под ваш домен/SPF/DKIM)
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

## Если почта не нужна (локалка/дев)

Оставьте `SMTP_HOST` **пустым** — обёртка молча отбрасывает письма и не роняет
`mail()`. Это дефолт для локальной разработки.

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

Диагностика доставки (лог msmtp пишется в stderr контейнера):

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
| [`mail/wp-sendmail.sh`](mail/wp-sendmail.sh) | Обёртка: собирает аргументы `msmtp` из `SMTP_*`, пустой `SMTP_HOST` = drop |
| [`php/php.ini`](php/php.ini) | `sendmail_path = "/usr/local/bin/wp-sendmail"` |
| [`Dockerfile`](Dockerfile) | Ставит `msmtp` + `ca-certificates`, копирует обёртку в образ |
| [`docker-compose.yml`](docker-compose.yml) | Anchor `x-smtp-env` пробрасывает `SMTP_*` в `wordpress` и `wp-cron` |

## Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| Письма не уходят, в логе тихо | `SMTP_HOST` пуст | Заполните SMTP-блок в `.env`, перезапустите |
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
SMTP_FROM=wordpress@example.com  # sender address (match your domain SPF/DKIM)
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

## When you don't need mail (local/dev)

Leave `SMTP_HOST` **empty** — the shim drops messages silently without failing
`mail()`. This is the default for local development.

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

Delivery diagnostics (msmtp logs to the container's stderr):

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
| [`mail/wp-sendmail.sh`](mail/wp-sendmail.sh) | Shim: builds `msmtp` args from `SMTP_*`; empty `SMTP_HOST` = drop |
| [`php/php.ini`](php/php.ini) | `sendmail_path = "/usr/local/bin/wp-sendmail"` |
| [`Dockerfile`](Dockerfile) | Installs `msmtp` + `ca-certificates`, copies the shim into the image |
| [`docker-compose.yml`](docker-compose.yml) | `x-smtp-env` anchor injects `SMTP_*` into `wordpress` and `wp-cron` |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No mail sent, log is quiet | `SMTP_HOST` empty | Fill the SMTP block in `.env`, restart |
| `authentication failed` | Wrong credentials | Check `SMTP_USER`/`SMTP_PASS` (SendGrid login = `apikey`) |
| `TLS handshake failed` on 465 | Port 465 without implicit TLS | `SMTP_PORT=465` + `SMTP_STARTTLS=off` |
| Mail goes to spam | Missing SPF/DKIM | Add DNS records for the `SMTP_FROM` domain |
| `cannot use a network` / timeout | Provider blocks the port | Switch port (587↔465) or provider |
