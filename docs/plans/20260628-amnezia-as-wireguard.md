# Amnezia-as-WireGuard: замена wg-shim нативной интеграцией

## Overview

Заменить bind-mount-обвязку `wg-shim` на нативную схему: пересобрать модуль AmneziaWG так, чтобы он регистрировался под именем `wireguard` (rtnl-link-тип и genl-семья), полностью вытесняя стоковый `wireguard.ko`. Тогда интерфейсы `wgcltN`, создаваемые UniFi через `ip link add type wireguard`, рождаются нативно AmneziaWG-совместимыми. Junk-параметры обфускации (`Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5`) доставляются на интерфейс через writable per-iface module-param (`iface_junk`), заполняемый из Mongo на boot и на udev-событие создания интерфейса.

**Проблема, которую решает:** провайдер режет WireGuard handshake → обфускация обязательна для самого факта коннекта. Текущий `wg-shim` (~880 строк) перехватывает `wg` через bind-mount, пересоздаёт iface как `amneziawg`, мёржит дампы и чинит PBR на каждый `wg show` — хрупко и с горячим Mongo-доступом.

**Ключевые выгоды:**
- нет bind-mount поверх `/usr/bin/wg`;
- нет мультиплексора дампа (одна genl-семья `wireguard`, стоковый `wg` видит всё сам — этому уже помогает существующий `netlink.c`-патч, вырезающий junk из dump);
- нет конверсии типа интерфейса;
- **нет PBR-репейра** — iface не пересоздаётся, ifindex стабилен, UCG-PBR не рушится;
- Mongo на холодном пути (boot + udev-add), не на каждый `wg show`.

## Context (from discovery)

**Исходники модуля** (`build.sh`, ref `v1.0.20260611` — последний апстрим; бамп с `20260322` безопасен, дельты только багфиксы `ispecs.desc`/init ispec-локов, патчируемые участки не задеты; репо `amnezia-vpn/amneziawg-linux-kernel-module`, src в `/build/amneziawg-linux-kernel-module/src`):
- `src/Kbuild:11,24` — имя модуля: `amneziawg-y := ...`, `obj-... := amneziawg.o` → задаёт `KBUILD_MODNAME = "amneziawg"`.
- `src/uapi/wireguard.h:160` — `#define WG_GENL_NAME "amneziawg"` (и `:161` `WG_GENL_VERSION 2`).
- `src/device.c:481` — `.kind = KBUILD_MODNAME` (rtnl link type).
- `src/device.c:291` — `device_type.name = KBUILD_MODNAME`.
- `src/device.c:359` — `wg_newlink(...)`, `:425` `register_netdevice(dev)` — точка инициализации устройства (анкер для инъекции junk до подъёма iface).
- `src/netlink.c:101` — консистенси-чек `strcmp(dev->rtnl_link_ops->kind, KBUILD_MODNAME)`.
- `src/netlink.c:989` — `genl_family.name = WG_GENL_NAME`.
- `src/netlink.c:779-847` — применение junk-атрибутов из netlink (`wg->jc`, `wg->jmin/jmax`, `wg->junk_size[...]`, magic headers, ispecs) — референс полей, которые надо выставить при инъекции.
- `src/main.c:88-89` — `MODULE_ALIAS_RTNL_LINK(KBUILD_MODNAME)`, `MODULE_ALIAS_GENL_FAMILY(WG_GENL_NAME)`.

**Текущая обвязка в репо** (удаляется/уходит в legacy): `scripts/wg-shim` (`fetch_db_record` — референс схемы Mongo), `scripts/install-wg-shim.sh`, `scripts/uninstall-wg-shim.sh`, `scripts/restore-managed-iface.sh`, `scripts/amneziawg.rc.local`.

**Механизм патчинга (важно):** `build.sh` применяет правки **inline-функциями** `patch_awg_*` (sed/perl), вызываемыми на `build.sh:288-307`, а НЕ через `patches/ucg-fiber-amneziawg.patch` (тот файл — справочный артефакт, `git apply`/`patch` в репо нет). Любой новый патч (включая rename) надо добавлять такой же функцией `patch_awg_*` и вызывать в той же секции. Существующие правки: `patch_awg_socket_ipv6_fallback` (degrade IPv6), `patch_awg_device_dump` (вырезание junk из `wg_get_device_dump` → dump-совместимость со стоком, **сохраняется** — но именно поэтому junk не виден через любой dump), `patch_awg_unload_cleanup`, `patch_awg_unique_slab_names` (`*_ucgf`), `patch_awg_ctor_safe_slab_allocs`.

**Артефакт/Makefile/deploy на старых именах:** `build.sh:312,315-316` оперируют `amneziawg.ko`; `Makefile` target `verify` делает `grep amneziawg`/`ip link add type amneziawg`; `deploy.sh`/`output/` шлют `amneziawg.ko`+`awg`+`awg-quick`. Всё это ломается rename'ом → правится явно.

**awg-tools НЕ нужны (рекон роутера):** на боксе есть стоковые `wg`+`wg-quick` (пакет `wireguard-tools`), `awg`/`awg-quick` отсутствуют. udapi конфигурит туннель через `wg setconf`/`wg syncconf` (подтверждено strings в `ubios-udapi-server`), НЕ через wg-quick. После rename genl-семьи в `"wireguard"` стоковый `wg` бьёт прямо в наш модуль: `setconf/syncconf` (data-path udapi) и `show` (отладка) работают нативно. Junk инжектится ядром из `iface_junk` → userspace-инжектор (`awg set`) не нужен. Поэтому amneziawg-tools из сборки/деплоя **исключаются** (`build.sh` секцию сборки tools убрать; `output/awg`,`output/awg-quick` не деплоить). Junk не виден ни через какой dump (его режет `patch_awg_device_dump`) — применение junk проверяется только handshake/tcpdump/временным `pr_info`.

**Рекон роутера (UCG-Fiber, kernel `5.4.213-ui-ipq9574`):**
- `wireguard` — загружаемый модуль (`/lib/modules/.../net/wireguard/wireguard.ko`), `refcnt=0`, holders пусто (netdev не пинит модуль).
- Один туннель `wgclt30` — сейчас чистый WireGuard; других потребителей стокового WG нет (нет Teleport-wg/wgsrv/site-to-site; `tunovpnc10` = OpenVPN).
- udev: `systemd-udevd`, `/etc/udev/rules.d` пишется, net-интерфейсы проходят через udev.
- Boot-путь: `/etc/rc.local` (есть) + PBR через `/etc/iproute2/rt_tables.d/pbr.conf`.
- Mongo: порт `27117`, db `ace`, коллекция `networkconf`; поиск `{wireguard_id:N, purpose:'vpn-client', vpn_type:'wireguard-client'}`; поле `wireguard_client_configuration_file` (полный AWG-конфиг с junk), плюс `enabled/ip_subnet/ipv6_subnet/interface_mtu`. Имя iface `wgcltN`, где `N == wireguard_id`.

## Development Approach

- **Testing approach: Regular (pragmatic).** В проекте нет unit-тест-харнеса; модуль ядра собирается в Docker, проверка — на живом роутере. «Тесты» в каждой задаче = (а) модуль собирается без ошибок в Docker, (б) целевые smoke-проверки на роутере (загрузка, genl-имя, наличие `iface_junk`, подъём туннеля, факт обфусцированного handshake, целостность PBR). Где возможно — selftest-сборка модуля (`CONFIG_AMNEZIAWG_DEBUG`/`src/selftest`).
- маленькие сфокусированные изменения, каждая задача завершается сборкой + проверкой;
- backward-compat: инвариант **нет записи в `iface_junk` → junk=0 → обычный WireGuard** (не ломает гипотетический Teleport/site-to-site);
- держать этот файл в синхроне с реальной работой (➕ новые задачи, ⚠️ блокеры).

- **Build-gate (Docker, только компиляция):** после каждой правки модуля — `make build` должен проходить; vermagic == `5.4.213-ui-ipq9574`. `src/selftest` НЕ покрывает junk/genl-name/rename (он про allowedips/ratelimiter) — он лишь подтверждает, что сборка не развалилась.
- **On-router smoke (единый скрипт `awg-status.sh`, см. Task 9 — вынести раньше и переиспользовать во всех verify):** наш ли модуль загружен (есть `iface_junk`), genl-семья `wireguard`, карта `iface_junk`, состояние PBR, ifindex-стабильность. Применение junk проверяется НЕ дампом, а handshake-success + `tcpdump` + временным `pr_info` (см. Technical Details).
- **Откат-тест:** вернуть стоковый `wireguard.ko` (+`depmod`) + снять udev-правило/rc.local-хук → `wgclt30` поднимается как раньше.
- Нет UI/e2e-тестов в проекте — раздел не применим.

## Progress Tracking

- `[x]` сразу по факту; ➕ новые задачи; ⚠️ блокеры; синхронизировать при отклонении scope.

## Solution Overview

**Архитектура — два слоя:**

1. **Kernel** (`amneziawg` пересобран как `wireguard`):
   - rename через два макроса (`KBUILD_MODNAME`, `WG_GENL_NAME`);
   - writable `module_param(iface_junk, charp, 0644)` — строковая карта `"wgclt30=jc:4,jmin:8,jmax:80,s1:86,s2:574,h1:...;wgclt31=..."`;
   - на `wg_newlink` модуль ищет запись по `dev->name` → инициализирует junk-поля устройства **до** `register_netdevice` (junk с пакета №1);
   - store-callback `iface_junk` двойного назначения: при записи проходит по живым iface нашего link-типа и ретроактивно применяет junk совпавшим (закрывает cold-start без cron/демона).

2. **Userspace** (stateless, event/boot-driven, без демонов и крона):
   - **boot-populator** из `/etc/rc.local`: `rmmod wireguard` → `insmod` нашего модуля → читает все enabled amnezia vpn-client из Mongo → формирует строку → пишет в `/sys/module/wireguard/parameters/iface_junk`;
   - **udev-правило** `KERNEL=="wgclt*", ACTION=="add"` → `populate-one %k`: тянет junk одного `wireguard_id` из Mongo, дописывает его запись → ядро применяет ретроактивно.

**Ключевые решения:**
- rename через имя модуля в `Kbuild` + `WG_GENL_NAME` (новая функция `patch_awg_rename_to_wireguard` в `build.sh`) — `KBUILD_MODNAME` распространяется на `.kind`, alias, device_type, консистенси-чек разом.
- **детерминированное вытеснение стокового `wireguard`** (boot-критично): genl-семья и rtnl-link-тип `wireguard` уникальны kernel-wide. Стоковый `wireguard.ko` в `/lib/modules` с живыми `MODULE_ALIAS_RTNL_LINK("wireguard")`/`MODULE_ALIAS_GENL_FAMILY("wireguard")` будет **автозагружен** первым же `ip link add type wireguard` или genl-запросом семьи `wireguard` (udapi/`wg` на раннем boot) → наш `insmod` упадёт с `-EEXIST` → туннели молча без обфускации. Лечение: заменить `/lib/modules/.../wireguard.ko` нашим + `depmod -a` (alias резолвит в наш), либо blacklist стока в `/etc/modprobe.d` + гарантия порядка. Голый `rmmod→insmod` уязвим к гонке (между ними автозагрузится сток).
- инъекция в kernelspace (а не userspace `awg set`) — нет окна утечки для туннелей, известных на boot. Trade-off: in-kernel string-парсер `iface_junk` — самая большая новая поверхность риска (kernel-баг = oops); держать минимальным, переиспользовать границы из `device.c:564-599`. Альтернатива (push junk userspace `awg set`, kernel-инъекция только в pre-register окне) убрала бы парсер, но всё равно требует in-kernel store, читаемый на NEWLINK без утечки → не упрощает существенно.
- junk-store пишется через sysfs (`module_param charp`, лимит записи PAGE_SIZE 4096 — для one-to-few туннелей запас огромный).

## Technical Details

**Формат `iface_junk`:** записи через `;`, поля через `,`, `ключ:значение`. Ключи: `jc,jmin,jmax,s1,s2,s3,s4,h1,h2,h3,h4,i1,i2,i3,i4,i5`. Числовые — `u16`; `h1-h4` — magic header genspec (строка, как в `magic_header.c`); `i1-i5` — ispec desc-строки. Парсер переиспользует валидацию/границы из `device.c:564-599` (`jc<0`, `jmin==jmax`, `junk_size + MESSAGE_*_SIZE > MESSAGE_MAX_SIZE`).

**Применение junk** = выставить те же поля `wg_device`, что netlink-путь (`netlink.c:779-847`): `wg->jc`, `wg->jmin`, `wg->jmax`, `wg->junk_size[MSGIDX_*]`, `wg->headers[MSGIDX_*]` (через `mh_parse`/genspec из `magic_header.c`), `wg->ispecs[0..4].desc` (через `junk.c`). Делать под `wg->device_update_lock`.

**Ретроактивный обход живых iface:** walk-функция размещается в `device.c` (там видны `static link_ops` и `device_list`), вызывается из store-callback. Парсить новую строку **до** `rtnl_lock` (тяжёлый разбор genspec/ispec не под rtnl), затем под `rtnl_lock()` — обход с фильтром `dev->rtnl_link_ops == &link_ops`, per-dev `device_update_lock` внутри. Порядок `rtnl → device_update_lock` совпадает с netlink-путём → deadlock'а нет (param_lock никто не берёт под rtnl). `for_each_netdev` без `struct net` идёт по `init_net` — на UCG туннели в init_net, ок.

**Проверка применения junk (нет dump-видимости!):** `awg show jc/s1` НЕ работает (rename семьи + dump-strip). Сигналы факта обфускации: (1) успешный handshake сквозь блокирующего провайдера — главный; (2) `tcpdump` на WAN — junk-пакеты/нестандартные размеры до handshake; (3) временный `pr_info("%s: applied jc=%u jmin=%u s1=%u ...\n", dev->name, wg->jc, ...)` в `apply_junk_to_dev` (или debugfs-атрибут) на время отладки. Содержимое `/sys/module/wireguard/parameters/iface_junk` = только намерение, не состояние девайса.

**udev → mongo без kill:** udev убивает RUN-процессы по таймауту (вся process-group, `&` не спасает). `populate-one` запускать через `systemd-run --no-block --unit=awg-populate@%k` (или `ENV{SYSTEMD_WANTS}+="awg-populate@%k.service"`, oneshot) — mongo-работа уезжает в отдельный юнит вне udev-таймаута.

**Mongo→строка (userspace):** `mongo --port 27117 --quiet ace --eval '...'` — выбрать enabled vpn-client, распарсить `wireguard_client_configuration_file`, извлечь junk-строки, собрать `wgcltN=...`. Референс запроса/полей — `fetch_db_record` в `scripts/wg-shim`.

**Guard загрузки нашего модуля:** уникальный признак — наличие `/sys/module/wireguard/parameters/iface_junk` (у стокового модуля его нет). rc.local проверяет; если параметра нет → значит загружен сток → `rmmod` + `insmod` наш.

## What Goes Where

- **Implementation Steps** (`[ ]`): правки исходников модуля, `build.sh`, новые userspace-скрипты, udev-правило, README/deploy.
- **Post-Completion** (без чекбоксов): проверка на живом роутере под реальным блокирующим провайдером, наблюдение reconnect/rekey, поведение после firmware-update.

## Implementation Steps

### Task 1: Rename module to register as `wireguard` (build.sh patch fn)

**Files:**
- Modify: `build.sh` (новая функция `patch_awg_rename_to_wireguard` + вызов + переименование артефакта)
- Modify: `Makefile` (`compare-amnezia` артефакт `wireguard.ko`)

- [x] добавить `patch_awg_rename_to_wireguard()` рядом с прочими `patch_awg_*`: `sed` по `Kbuild` (`amneziawg-y`→`wireguard-y`, `:= amneziawg.o`→`wireguard.o` → `KBUILD_MODNAME="wireguard"`) и `uapi/wireguard.h` (`WG_GENL_NAME "amneziawg"`→`"wireguard"`) + assert'ы применения
- [x] вызвать функцию в секции патчей (Patch 9, до `make`)
- [x] заменить `modinfo amneziawg.ko`/`cp amneziawg.ko` на `wireguard.ko`; сохранить vermagic-проверку
- [x] подтвердить, что `.kind`/`device_type.name`/`MODULE_ALIAS_*`/`netlink.c:101` подхватывают имя через макросы (точечных правок не требуется); slab `*_ucgf` оставить как есть
- [x] build-gate: `make build` проходит; `modinfo output/wireguard.ko` → имя `wireguard`, `alias rtnl-link-wireguard` + `net-pf-16-proto-16-family-wireguard`, vermagic `5.4.213-ui-ipq9574` ✓ (Docker build exit 0)

### Task 2: Stop building amneziawg-tools

**Files:**
- Modify: `build.sh` (убрать секцию сборки `awg`/`awg-quick`)

- [x] удалить секцию сборки amneziawg-tools в `build.sh` (стоковый `wg`+`wg-quick` уже на роутере, udapi использует `wg setconf/syncconf`)
- [ ] build-gate: `make build` даёт только `output/wireguard.ko` (без `awg`/`awg-quick`); на роутере `wg show wgclt30` работает против нашего модуля (семья `wireguard`)
- *Примечание:* удаление `awg`/`awg-quick` из `deploy.sh` и target `verify` в `Makefile` консолидировано в Task 10 (там `deploy.sh` переписывается целиком под новый дизайн — частичная правка дала бы несогласованный файл).

### Task 3: Add writable per-iface junk-store module param + parser

**Files:**
- Create: `src/iface_junk.c`, `src/iface_junk.h`
- Modify: `src/Kbuild` (добавить `iface_junk.o` в `wireguard-y`); правки вносить патч-функцией в `build.sh`

- [x] `module_param_cb(iface_junk, &iface_junk_ops, 0644)` с собственным локом (не голый `charp` — иначе UAF при swap-гонке с newlink); хранит копию строки
- [x] парсер TAB-формата `<ifname>\t<k>=<v>...` → зеркалит setconf; вместо дублирования валидации зовёт готовую `wg_device_handle_post_config()` (она и валидирует, и делает `jp_spec_setup`)
- [x] `iface_junk_find_record(ifname)` — поиск записи по имени в строке параметра
- [x] `wg_iface_junk_apply(wg)` под `wg->device_update_lock`; `pr_info` с применёнными jc/s1 (отладка), на ошибку — `advanced_security=false` + `net_warn`, fallback в plain WG
- [x] build-gate: компиляция чистая; `modinfo` показывает parm `iface_junk`; символы `wg_iface_junk_apply`/`iface_junk_set/get` в `.ko` ✓
- [ ] on-router: `/sys/module/wireguard/parameters/iface_junk` существует, читается/пишется (pending — maintenance window)

### Task 4: Apply junk on NEWLINK before register_netdevice

**Files:**
- Modify: `src/device.c` (в `wg_newlink`, до `register_netdevice` на :425) — через патч-функцию в `build.sh`

- [x] до `register_netdevice` (под держащимся RTNL): `wg_iface_junk_apply(wg)` ищет запись по `dev->name` → применяет (junk с пакета №1). Хук врезан в `wg_newlink` (5.4 идёт через `wg_newlink_old`→`wg_newlink`, единая точка)
- [x] инвариант: нет записи → `return 0`, junk=0 (обычный WireGuard), стандартный путь не регрессирует
- [x] битая запись → `net_warn` + `advanced_security=false`, iface всё равно поднимается
- [x] build-gate: компиляция чистая, хук-assert в `build.sh` пройден
- [ ] verify (router): при заполненном `iface_junk` `ip link add wgcltX type wireguard` → `pr_info` в `dmesg` показывает ненулевой jc/s1; handshake поднимается сквозь провайдера (pending)
- [ ] verify: без записи → `dmesg` показывает junk=0, ведёт себя как чистый WG (pending)

### Task 5: Retroactive apply in store-callback (walk live ifaces)

**Files:**
- Modify: `src/device.c` (walk-функция — там видны `static link_ops`/`device_list`)
- Modify: `src/iface_junk.c` (вызов walk из store-callback)

- [x] swap строки под `iface_junk_lock`, затем walk под `rtnl_lock()` по `wg_device_list()` (accessor к static `device_list`), `wg_iface_junk_apply` per-dev берёт `device_update_lock` внутри (порядок rtnl→device_update_lock как в netlink → без deadlock; walk вне `iface_junk_lock` — `find_record` берёт его заново)
- [x] для каждого live-iface вызывается тот же `wg_iface_junk_apply` что и в newlink → идентичный набор полей (идемпотентно)
- [x] build-gate: компиляция чистая, символ `wg_device_list` в `.ko` ✓
- [ ] verify (router): поднять чистый `wgcltX`, затем `printf 'wgcltX\tjc=4\t...' > .../iface_junk` → `dmesg` подтверждает применение без пересоздания iface; handshake восстанавливается (pending)
- [ ] verify: `ip link show wgcltX` — ifindex не изменился (PBR цел) (pending)

### Task 6: Suppress stock wireguard autoload/collision (boot-critical)

**Files:**
- Create: `scripts/install-module.sh` (replace `/lib/modules` + `depmod`)

- [x] стратегия (a): заменить `/lib/modules/.../wireguard.ko` нашим + `depmod -a` → autoload `type wireguard` резолвит наш (нет гонки/`-EEXIST`); бэкап стока в `wireguard.ko.stock`. Маркер «наш» = parm `iface_junk`. `/lib/modules` writable (проверено)
- [x] гонка `rmmod→insmod` снята: файл В `/lib/modules` уже наш → autoload берёт наш. rmmod стока только если нет живых iface (ранний boot), иначе громкий WARNING
- [x] `-EEXIST` исключён by design (один `wireguard.ko` по имени); идемпотентно, переживает firmware-revert (re-run на boot)
- [ ] verify (router): после применения `ip link add type wireguard`/genl-запрос резолвят в НАШ модуль (есть `iface_junk`); на reboot сток не перехватывает (pending — maintenance window)

### Task 7: Boot-populator + rc.local hook

**Files:**
- Create: `scripts/awg-boot.sh`
- Create: `scripts/populate-junk.sh` (Mongo→sysfs, общий для boot и udev)
- Create: `scripts/awg.rc.local` (заменяет `amneziawg.rc.local`)

- [x] `awg-boot.sh`: вызывает `install-module.sh` (гарантия нашего модуля), затем `populate-junk.sh`; лог в `awg-boot.log`
- [x] `populate-junk.sh`: mongo (порт 27117, db ace) находит все enabled vpn-client, парсит `wireguard_client_configuration_file` (Jc/S1/H1/I1...→jc/s1/h1/i1), пишет TAB-формат в `iface_junk`; авторитетная полная перезапись; пустой Mongo → пустая строка
- [x] `awg.rc.local`: вызов `awg-boot.sh` перед `exit 0`; задокументирован риск порядка после firmware-update
- [ ] verify (router): reboot → наш модуль активен, `wgclt30` (boot-known) поднимается с обфусцированным handshake, `dmesg`/`pr_info` подтверждает junk (pending)
- [ ] verify: `ip -4 rule show | grep wgclt30` и таблица `179.wgclt30` целы (pending)

### Task 8: Per-iface udev populator via systemd-run (cold-start)

**Files:**
- Create: `scripts/awg-populate@.service` (systemd template, oneshot)
- Create: `scripts/99-amnezia-wgclt.rules` (udev)

- [x] udev-правило: `SUBSYSTEM=="net", KERNEL=="wgclt*", ACTION=="add", ENV{SYSTEMD_WANTS}+="awg-populate@%k.service"` (НЕ прямой `RUN+=mongo` — udev убьёт по таймауту)
- [x] `awg-populate@.service` → `populate-junk.sh` (полная авторитетная перезапись вместо per-iface merge — проще и идемпотентно); ядро применяет ретроактивно (Task 5)
- [x] disabled/нет записи в Mongo → `populate-junk.sh` пишет только enabled → остаётся чистым WG
- [ ] установка правила+юнита (`/etc/udev/rules.d/`, `udevadm control --reload`) — делается в install (Task 10)
- [ ] verify (router): добавить новый vpn-client в UI → в пределах ~WG-ретрая (≤5с, known-window: 1-2 первых handshake чистые — для handshake-blocking провайдера ок) коннектится; `dmesg` подтверждает retroactive-apply (pending)

### Task 9: Health-check `awg-status.sh` + invariant

**Files:**
- Create: `scripts/awg-status.sh`
- Modify: `scripts/awg-boot.sh` (усилить guard)

- [x] `awg-status.sh`: наш ли модуль (есть `iface_junk`), genl-семья `wireguard`, карта `iface_junk`, per-iface состояние через стоковый `wg show` (интерфейс/handshake — НЕ junk), PBR, ifindex; единый smoke для verify
- [x] guard: `install-module.sh` (зовётся из `awg-boot.sh`) при отсутствии `iface_junk` после install → громкий лог + `exit 1`
- [ ] инвариант в README: «нет записи в `iface_junk` → junk=0 → обычный WireGuard» (Task 12)
- [ ] verify (router): `awg-status.sh` даёт корректную картину при поднятом `wgclt30` (pending)

### Task 10: Retire wg-shim (legacy) + Makefile/deploy fix

**Files:**
- Modify: `Makefile` (target `verify`: `grep wireguard`/`type wireguard`; `deploy` список)
- Modify: `deploy.sh` (scp-список: `wireguard.ko`+новые скрипты+udev+service; БЕЗ `awg`/`awg-quick`)
- Modify: `README.md`
- Modify (move): `scripts/wg-shim`, `install-wg-shim.sh`, `uninstall-wg-shim.sh`, `restore-managed-iface.sh`, `amneziawg.rc.local` → `scripts/legacy/`

- [x] `Makefile` target `verify` под имя `wireguard` (проверка `iface_junk` + `awg-status.sh`); `compare-amnezia` → `wireguard.ko`
- [x] `deploy.sh` переписан: недеструктивно (копирует модуль+скрипты, ставит udev-правило+systemd-юнит); деструктивный swap модуля — отдельной командой; `INSTALL_RC_LOCAL=1` для boot-хука; блок отката
- [x] shim-скрипты → `scripts/legacy/` + `scripts/legacy/README.md` (deprecated); stale `output/*.ko`/`awg` сняты с трекинга + в `.gitignore`
- [x] README переписан под amnezia-as-wireguard (build/deploy/activate/verify/rollback/инвариант/firmware-caveat)
- [ ] verify (router): `make deploy` копирует корректный набор; команды воспроизводимы (pending)

### Task 11: Verify acceptance criteria

- [ ] чистый boot: загружен наш `wireguard` (genl `wireguard`, есть `iface_junk`), сток вытеснен, нет `-EEXIST`
- [ ] `wgclt30` (boot-known) поднимается, handshake проходит сквозь блокирующего провайдера; `tcpdump` на WAN показывает junk до handshake
- [ ] новый туннель из UI коннектится в пределах ~5с (udev cold-start через systemd-run)
- [ ] PBR (`iif`/`fwmark`/`from-src`/таблица `179.wgclt30`) цел, ifindex стабилен
- [ ] стоковый `wg show all dump` от udapi не подавился (dump-strip), UI видит туннель «зелёным»
- [ ] инвариант: iface без записи в `iface_junk` = обычный WireGuard
- [ ] откат: возврат стокового модуля + снятие хуков восстанавливает прежнее поведение
- [ ] убрать временные `pr_info` из `apply_junk_to_dev` (или перевести в debug-уровень)

### Task 12: Update documentation
- [ ] финализировать README.md (архитектура amnezia-as-wireguard, `awg-status.sh`, откат, инвариант)
- [ ] обновить CLAUDE.md, если выявлены новые паттерны проекта
- [ ] переместить этот план в `docs/plans/completed/`

## Post-Completion

*Только ручные/внешние действия — без чекбоксов.*

**Manual verification:**
- длительное наблюдение под реальным блокирующим провайдером: reconnect, rekey (~каждые 2 мин), стабильность handshake;
- поведение после firmware-update UCG: апдейт вернёт стоковый `wireguard.ko` (откатит replace/depmod из Task 6) → убедиться, что `awg-boot.sh` на следующем boot повторно вытесняет сток; при необходимости — стратегия раннего запуска до сети;
- стресс: одновременный подъём нескольких `wgcltN`, корректность merge `iface_junk` под гонкой udev-событий.

**External system updates:**
- если включат Teleport/site-to-site/WG-server — подтвердить, что без записи в `iface_junk` они работают как чистый WireGuard;
- зависимость от схемы Mongo (`ace.networkconf`): при обновлении прошивки UniFi проверить, что имена полей не поменялись (`wireguard_client_configuration_file`, `wireguard_id`, `purpose`, `vpn_type`).
