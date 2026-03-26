# Files

## Что заливать в GitHub

### Обязательно

- `README.md`
- `FILES.md`
- `Makefile`
- `Dockerfile`
- `build.sh`
- `deploy.sh`
- `kernel.config`
- `patches/ucg-fiber-amneziawg.patch`
- `scripts/wg-shim`
- `scripts/install-wg-shim.sh`
- `scripts/uninstall-wg-shim.sh`
- `scripts/restore-managed-iface.sh`
- `scripts/amneziawg.service`

### Опционально

- `output/amneziawg.ko`
- `output/awg`
- `output/awg-quick`

Если репа public, лучше держать эти файлы в release assets, а не в истории git.

## Что не надо заливать в GitHub

- `.DS_Store`
- `.claude/`
- `.tmp-amneziawg-src/`
- `wireguard-device.ko`

## Что копировать на роутер

### Для ручного AWG без UI takeover

Скопировать:

- `output/amneziawg.ko`
- `output/awg`
- `output/awg-quick`

Команда:

```bash
scp \
  output/amneziawg.ko \
  output/awg \
  output/awg-quick \
  root@192.168.1.1:/data/amneziawg/
```

### Для пути через UniFi UI + wg-shim

Скопировать:

- `output/amneziawg.ko`
- `output/awg`
- `output/awg-quick`
- `scripts/wg-shim`
- `scripts/install-wg-shim.sh`
- `scripts/uninstall-wg-shim.sh`
- `scripts/restore-managed-iface.sh`

Команда:

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

### Опционально на роутер

- `scripts/amneziawg.service` — если хочешь автозагрузку модуля

## Что не нужно копировать на роутер

- `build.sh`
- `Dockerfile*`
- `kernel.config`
- `patches/`
