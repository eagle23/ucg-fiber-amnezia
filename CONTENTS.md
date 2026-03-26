# upload-to-github

Эта папка уже собрана для загрузки в GitHub.

Что внутри:

- корневые файлы репозитория
- `patches/`
- только нужные `scripts/` для текущего Mongo-backed `wg-shim`
- `output/` с готовыми артефактами:
  - `amneziawg.ko`
  - `awg`
  - `awg-quick`

Если не хочешь хранить бинарники в git history, просто удали:

```bash
rm -rf output
```

Остальное можно публиковать как есть.
