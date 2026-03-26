# unifi-amneziawg

Порт AmneziaWG под UniFi router.

В репе сейчас есть три рабочих куска:

1. patched `amneziawg.ko` для kernel `5.4.213-ui-ipq9574`
2. userspace `awg` и `awg-quick`
3. `wg-shim`, который перехватывает `wg syncconf/setconf` от UniFi UI, читает исходный AWG-конфиг из Mongo `ace.networkconf`, пересоздаёт `wgcltN` как `amneziawg` и долечивает PBR

## Что сейчас умеет

- `output/amneziawg.ko` загружается на роутер
- `output/awg` и `output/awg-quick` поднимают AWG вручную
- `scripts/wg-shim` позволяет включать клиентский VPN через UniFi UI и забирать AWG-поля из БД, а не из временного `wg syncconf` файла
- `wg-shim` восстанавливает policy routing не только в момент `syncconf`, но и во время регулярного `wg show all dump`, потому что UCG дорисовывает свои `ip rule` позже

Ограничения:

- поддержан путь для `vpn-client` / `wgcltN`
- `wgsrvN` этим shim пока не ведётся
- `mark` и `lookup table` у UCG runtime-only, хардкодить их нельзя

## Сборка

Нужен Docker.

Собрать AmneziaWG:

```bash
make build
```

Результат:

- `output/amneziawg.ko`
- `output/awg`
- `output/awg-quick`

## Минимальный деплой на роутер

Если нужен только AWG вручную, без интеграции с UI:

```bash
scp \
  output/amneziawg.ko \
  output/awg \
  output/awg-quick \
  root@192.168.1.1:/data/amneziawg/
```

Если нужен путь через UniFi UI и `wg-shim`:

```bash
scp \
  output/amneziawg.ko \
  output/awg \
  output/awg-quick \
  scripts/wg-shim \
  scripts/install-wg-shim.sh \
  scripts/uninstall-wg-shim.sh \
  scripts/restore-managed-iface.sh \
  root@192.168.1.1:/data/amneziawg/
```

Потом на роутере:

```bash
chmod +x /data/amneziawg/awg \
         /data/amneziawg/awg-quick \
         /data/amneziawg/wg-shim \
         /data/amneziawg/install-wg-shim.sh \
         /data/amneziawg/uninstall-wg-shim.sh \
         /data/amneziawg/restore-managed-iface.sh

rmmod amneziawg 2>/dev/null || true
insmod /data/amneziawg/amneziawg.ko
/data/amneziawg/install-wg-shim.sh /data/amneziawg/wg-shim
```

После этого UniFi UI продолжает вызывать обычный `wg`, а shim:

- ловит `wg syncconf` / `wg setconf`
- вытаскивает `wireguard_id` из имени `wgcltN`
- читает `wireguard_client_configuration_file` из Mongo
- если там есть AWG-поля и профиль включён, переводит интерфейс в `amneziawg`

## Как это работает на роутере

Проверено, что `ubios-udapi-server` использует:

```bash
wg show all dump
wg syncconf wgcltN /run/wireguard_*.config
```

То есть `wg-quick` для UI не участвует.

Поэтому основной путь интеграции такой:

1. UniFi UI создаёт или обновляет `wgcltN`
2. `wg-shim` перехватывает `syncconf`
3. берёт полный AWG-конфиг из `ace.networkconf`
4. создаёт `amneziawg` под тем же именем интерфейса
5. восстанавливает адреса, маршруты и policy routing

## Файлы в репе

Основные:

- `build.sh` — сборка patched AmneziaWG
- `Makefile` — удобные команды `make build` и `make deploy`
- `kernel.config` — kernel config, которым кормится сборка
- `patches/ucg-fiber-amneziawg.patch` — патч для AWG source

Скрипты для роутера:

- `scripts/wg-shim`
- `scripts/install-wg-shim.sh`
- `scripts/uninstall-wg-shim.sh`
- `scripts/restore-managed-iface.sh`
- `scripts/amneziawg.service`

Готовые артефакты:

- `output/amneziawg.ko`
- `output/awg`
- `output/awg-quick`

## Отладка на роутере

Проверить, что AWG-интерфейс жив:

```bash
IFACE="wgcltN"
/data/amneziawg/awg show "$IFACE"
/data/amneziawg/awg show "$IFACE" latest-handshakes
/data/amneziawg/awg show "$IFACE" transfer
```

Проверить PBR:

```bash
IFACE="wgcltN"
IPV4="$(ip -o -4 addr show dev "$IFACE" scope global | awk 'NR == 1 { print $4 }' | cut -d/ -f1)"
IPV6="$(ip -o -6 addr show dev "$IFACE" scope global | awk 'NR == 1 { print $4 }' | cut -d/ -f1)"

ip -4 rule show | grep "$IFACE"
ip -6 rule show | grep "$IFACE"
[ -n "$IPV4" ] && ip -4 route get 1.1.1.1 from "$IPV4"
[ -n "$IPV6" ] && ip -6 route get 2606:4700:4700::1111 from "$IPV6"
```

Проверить shim:

```bash
IFACE="wgcltN"
cat /data/wg-shim/wg-shim.log
ls -l /data/wg-shim/iface-extra.d
wg show all dump | grep "^${IFACE}"
```

## Откат

Снять shim:

```bash
/data/amneziawg/uninstall-wg-shim.sh
```

Вернуть конкретный интерфейс обратно в stock WireGuard:

```bash
/data/amneziawg/restore-managed-iface.sh <iface>
```
