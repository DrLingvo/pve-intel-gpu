# pve-intel-gpu

Единый инструмент для Intel iGPU на Proxmox VE:

- **vGPU с автовыбором технологии по поколению iGPU**: GVT-g на Gen8–9
  (Broadwell … Comet Lake), SR-IOV на Gen12+ (Tiger Lake … Core Ultra)
- Профили гостей, в том числе **BlissOS / Android-x86** (`--guest android`)
- **Полный passthrough** с автовыбором ROM под поколение (6–14 / Ultra) — запасной вариант
- Детекция версий PVE / QEMU / ядра и поколения CPU
- Безопасный откат и гибкое логирование

## Зачем объединено

Включение функции и использование её как дисплея — звенья одной цепи.  
Отдельные репозитории создавали лишнюю путаницу.

## Установка

```bash
curl -fsSLO https://github.com/DrLingvo/pve-intel-gpu/releases/latest/download/install.sh
bash install.sh --yes          # или --release v0.3.0
pve-intel-gpu --mode status
```

`install.sh` сверяет все файлы релиза с `SHA256SUMS`, ставит их в `/opt/pve-intel-gpu`
(команда `/usr/local/sbin/pve-intel-gpu`), берёт общий lock host-tools и показывает,
совпадает ли версия контракта с realpc. Пакеты, ядро и ВМ он не трогает. Обновление:
`install.sh --mode update`, удаление: `install.sh --mode uninstall` (откажет, пока
изменения хоста не откачены через `pve-intel-gpu --mode revert`). Из локальной копии
репозитория: `install.sh --from . --yes`.

## Быстрый старт

```bash
pve-intel-gpu --mode status                          # поколение, технология vGPU, realpc
pve-intel-gpu --mode vgpu --yes                      # хост: GVT-g или SR-IOV, затем перезагрузка
pve-intel-gpu --mode vgpu --vmid 101 --guest android # ВМ BlissOS получает vGPU
pve-intel-gpu --mode passthrough --vmid 100          # запасной вариант: вся iGPU одной ВМ
```

## vGPU: какая технология где

| iGPU | Технология | Что получает ВМ |
| --- | --- | --- |
| Broadwell, Skylake, Kaby/Coffee/Comet Lake, Apollo Lake (Gen8–9) | GVT-g (`i915.enable_gvt=1`, `kvmgt`) | mdev `i915-GVTg_V5_*`; тип выбирается по свободным слотам или `--gvt-type` |
| Tiger/Rocket/Alder/Raptor Lake, Core Ultra (Gen12+) | SR-IOV (VF, при необходимости i915-sriov-dkms) | отдельная VF `00:02.N` |
| Haswell, Ice/Jasper/Elkhart Lake, Gemini Lake | нет | только `--mode passthrough` |

### BlissOS / Android-x86 (`--guest android`)

- GVT-g: экраном ВМ становится сам vGPU (`display=on`, `ramfb`, `egl-headless`,
  `vga: none`), консоль Proxmox (noVNC) показывает его вывод. `--display console`
  оставляет обычный `vga` ВМ.
- В загрузке BlissOS: без `nomodeset`; аппаратное видео — `FFMPEG_CODEC2_PREFER=1`,
  без `FFMPEG_HWACCEL_DISABLE`.
- SR-IOV: ядру гостя нужен драйвер VF i915 (i915-sriov-dkms в госте); у VF нет
  вывода изображения — экран через `vga` ВМ или scrcpy.

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

Известная граница контракта: откат realpc чистит из старой строки `args` только токены
`-set device.hostpciN.{addr,bus,x-igd-*}`. Если до `configvm` у ВМ уже был GVT-g-экран,
после отката `-display egl-headless` может оказаться в `args` дважды; `--mode check`
это показывает, `--mode reapply --vmid N` исправляет. Правильное решение — расширить
очистку в realpc на `display`/`ramfb`/`driver` и `-display egl-headless,…00:02.0…`.

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
