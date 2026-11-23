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

### Каталог `bios/`

Скрипт берёт ROM из `bios/`:

- `bios/*.rom` — сами файлы;
- `bios/SHA256SUMS` — контрольные суммы; ROM с несовпавшей или отсутствующей суммой не
  используется без `--force`;
- `bios/catalog.tsv` — какой ROM для какого PCI ID iGPU (побеждает самый длинный префикс)
  и минимальная версия QEMU.

Добавить свой ROM (файл, сумма и строки каталога обновятся сами):

```bash
./pve-intel-gpu.sh --mode rom-add --rom ~/12-n100-q10.rom --ids "46d1 46d0" --qemu 10 --source "моя сборка"
```

В ROM от AICodo зашиты проприетарные GOP-драйверы Intel. Пока они лежат в репозитории
для простоты; позже планируется выкладывать их через Releases.

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

## Совместная работа с realpc-clean-build

pve-intel-gpu и [realpc-clean-build](https://github.com/DrLingvo/realpc-clean-build)
рассчитаны на работу **вместе**: realpc даёт ВМ маскировку (QEMU/OVMF, ACPI, SMBIOS,
`kvm.ko`), pve-intel-gpu — изображение через iGPU. Оба меняют один хост и одни и те же ВМ,
поэтому правила записаны в общем [CONTRACT.md](CONTRACT.md), который лежит в обоих
репозиториях. Главное:

- общий lock `/run/lock/pve-host-tools.lock`;
- в строке `args:` скрипт меняет только свои токены `-set device.hostpciN.*` и кладёт их
  копию в `/etc/pve-host-tools/args.d/<vmid>/50-pve-intel-gpu.args`, чтобы `configvm`
  их сохранял;
- скрипт не трогает `kvm.ko`, `pve-qemu-kvm`, `pve-edk2-firmware` и APT hold;
- `--mode check` показывает состояние realpc и предупреждает, если контракт не совпадает
  или после `configvm` нужен `--mode reapply`.

Порядок: сначала `realpc-setup.sh` (`strong`, `configvm`), затем этот скрипт. Полный
откат — в обратном порядке. **Любая правка формата `args`, отката, state или блокировки
должна сверяться с CONTRACT.md и делаться в обоих репозиториях**; тесты этой стороны —
`bash tests/run.sh`.

## Статус

Логика vGPU и passthrough реализована и покрыта офлайн-тестами (`bash tests/run.sh`);
на реальном железе ещё не проверена — начинайте с `--mode status` и `--dry-run`.

## Источники

- Детекция и откат — из старого `pve-vgpu-setup`
- ROM-сборка — из [AICodo/intel6-14rom](https://github.com/AICodo/intel6-14rom) и [AICodo/intel-ultra-rom](https://github.com/AICodo/intel-ultra-rom)
