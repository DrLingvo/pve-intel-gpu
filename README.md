# pve-intel-gpu

Единый инструмент для Intel iGPU на Proxmox VE:

- Включение и настройка **vGPU / SR-IOV**
- **Полный passthrough** с автовыбором ROM под поколение (6–14 / Ultra)
- Детекция версий PVE / QEMU / ядра и поколения CPU
- Безопасный откат и гибкое логирование

## Зачем объединено

Включение функции и использование её как дисплея — звенья одной цепи.  
Отдельные репозитории создавали лишнюю путаницу.

## Быстрый старт

```bash
# подробный лог
LOG_LEVEL=debug ./pve-intel-gpu.sh --mode status

# подготовка хоста
./pve-intel-gpu.sh --mode prepare

# vGPU
./pve-intel-gpu.sh --mode vgpu

# полный passthrough конкретной ВМ
./pve-intel-gpu.sh --mode passthrough --vmid 100
```

Лог-файл называется так же, как скрипт (без `.sh`).

## ROM-файлы

### Сборка в GitHub Actions

Добавлен workflow `.github/workflows/build-roms.yml`.

Запустить вручную:
1. Зайти в Actions → Build iGPU ROMs
2. Run workflow
3. Выбрать `6-14`, `ultra` или `both`

Готовые `.rom` появятся в артефактах запуска.

### Ручная сборка / готовые файлы

Скрипты-ссылки:
- `roms/build-6-14.sh`
- `roms/build-ultra.sh`

Или брать готовые из Releases оригинальных репозиториев:
- https://github.com/AICodo/intel6-14rom/releases
- https://github.com/AICodo/intel-ultra-rom/releases

## Статус

Скелет + CI для сборки ROM.  
Реальная логика vGPU и passthrough — в разработке.

## Источники

- Детекция и откат — из старого `pve-vgpu-setup`
- ROM-сборка — из [AICodo/intel6-14rom](https://github.com/AICodo/intel6-14rom) и [AICodo/intel-ultra-rom](https://github.com/AICodo/intel-ultra-rom)
