# NVIDIA App — Automatic Tuning Fix

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20(64--bit)-lightgrey.svg)]()
[![Tested with NVIDIA App](https://img.shields.io/badge/NVIDIA%20App-v11.0.9%2B-green.svg)]()

A lightweight, automated fix for issues with **Automatic Tuning** (GPU auto-overclocking) in **NVIDIA App**:
1. **Toggle resets or fails to start** (0% stuck / immediately unchecks).
2. **Stuck slider / Ghost Tuning** (slider shows ON with +0 MHz, cannot be turned off, throws *"Something went wrong"*).
3. **Scan fails to start when enabling toggle** (throws *"Something went wrong"* due to background OC scan returning NvAPI error `-104` on newer GPUs/drivers like RTX 50-series / 621+).
4. **Authenticode integrity & Admin Consent** (configures registry consent natively, keeping digital signatures intact and preventing NvContainer error `2148098064`).

---

[English](#english) | [Русский](#русский)

---

<a name="english"></a>
## English

### Problem Description

Users of NVIDIA App frequently encounter one of these major bugs under **System -> Performance -> Automatic Tuning**:

#### Bug 1: Missing Plugin / Scan Never Starts
- When you toggle **Automatic Tuning** ON, nothing happens (progress remains at 0% or scan never starts).
- Switching to another tab and coming back resets the toggle to **Off**.
- Client logs show `completionStatus: 34` and timeouts/missing message handlers on the NVIDIA MessageBus.

#### Bug 2: Stuck Slider ON (+0 MHz) and Cannot Be Turned Off (v11.0.9+)
- After app or driver updates, the **Automatic Tuning** toggle appears permanently **ON**, but the GPU clock offset is **+0 MHz** (no overclock is active).
- Clicking the toggle to turn it **Off** results in a toast error: *"Something went wrong"* (`common.somethingWentWrong`), and the toggle immediately snaps back to **ON**.
- The "Restore" button is greyed out/disabled.

#### Bug 3: Background Scan Error (`-104`) Blocks Launching Scan
- When attempting to toggle Automatic Tuning **ON**, the app immediately shows a toast error *"Something went wrong"*, the slider never engages, and the tuning scan never runs.

---

### Technical Root Cause Analysis

#### Root Cause 1: Missing Plugin Junction in NvContainer
- NVIDIA App delegates background GPU management to `nvcontainer.exe`.
- The container discovers plugins via `%ProgramFiles%\NVIDIA Corporation\NvContainer\plugins\User\NVIDIA App`, which points to `Plugins\localuser`.
- The overclocking plugin (`_OverClockingNvc.dll`) is placed by the installer into `Plugins\oc`.
- In the installer manifest (`NvApp.nvi`), NVIDIA configured junctions for most plugins (desktop, systeminfo, updater, etc.), but **omitted creating a junction for `oc`**.
- As a result, `nvcontainer.exe` never loads `_OverClockingNvc.dll` into memory, causing any `EnableBackgroundOcScan` call to fail silently.

#### Root Cause 2: Frontend State Logic Flaw
In NVIDIA App 11.0.9, NVIDIA introduced a new native CEF plugin `CEF\plugins\NVIDIA App\NvOc.dll` and updated the frontend UI logic:
1. When the performance page loads, the frontend calls `getAutoTuneToggleState()` in `www\main.*.js`:
   ```javascript
   getAutoTuneToggleState() {
       return this.scanResultNotification$.pipe(
           (0, c.T)(W => W.stable || 0 === W.type)
       );
   }
   ```
2. When no scan has ever succeeded, NvAPI returns `completionStatus: 34`, `averageGpuClockOffsetMhz: 0`, and `stable: 1` (indicating stock clocks are stable).
3. Because `W.stable` is `1` (truthy in JavaScript), the UI concludes that Automatic Tuning is **enabled**, rendering the toggle as **ON** despite +0 MHz offset!

#### Root Cause 3: Background OC Scan Call Failing on Newer Drivers/GPUs (NvAPI `-104`)
1. In `www\main.*.js`, starting a tuning scan calls:
   ```javascript
   enableBgOcScanAndStartScan() {
       return this.enableBackgroundOcScan(!0).pipe(
           (0, S.n)(W => W ? this.startOcScan() : (this.logger.error("..."), (0, s.of)(!1)))
       );
   }
   ```
2. On newer drivers (such as 621.14) and architectures, `NvAPI_GPU_ClientEnableBackgroundOcScanner` returns `-104 (NVAPI_NOT_SUPPORTED)`.
3. Because `enableBackgroundOcScan(!0)` expects driver background scanning to succeed, it throws an error:
   ```
   ERROR nvapp/PerfTuningService Some error occured in EnableBackgroundOcScan [object Object]
   ```
4. This aborts execution before `this.startOcScan()` is ever called, triggers the *"Something went wrong"* popup, and blocks tuning.

#### Root Cause 4: Digital Signature Enforcement in NvContainer
- `NvContainer` verifies Authenticode digital signatures on all loaded DLLs via `NvcPluginLoadHelper`.
- Binary patching `_OverClockingNvc.dll` invalidates the signature (`CERT_E_WRONG_USAGE` / Error `2148098064`), causing NvContainer to reject loading it completely.
- Admin Consent is instead managed cleanly and natively via the Windows Registry key `HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC\<User-SID>`, ensuring zero binary modification and full signature validity.

> [!NOTE]
> **Hardware Architecture Note (RTX 50-series / Blackwell)**:
> In display driver 621.14, NVIDIA has temporarily disabled automated V/F curve scanning (`NvAPI_GPU_ClientStartOcScanner`) in `nvldkm.sys` for Blackwell GPUs (`NVAPI_NOT_SUPPORTED: -104`). Manual frequency and voltage offsets remain functional in NVIDIA App and MSI Afterburner while waiting for subsequent driver updates.

---

### What the Fix Does

1. **Restores Overclocking Plugin**: Creates the NTFS junction `Plugins\localuser\oc` ➔ `Plugins\oc` so `nvcontainer.exe` can discover and load `_OverClockingNvc.dll`.
2. **Restores Original Signed Plugin**: Reverts any modified `_OverClockingNvc.dll` back to the official signed NVIDIA binary to ensure digital signature checks pass (`Valid`).
3. **Configures Admin Consent**: Automatically writes the required user consent keys to `HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC` for all active user profiles.
4. **Fixes Slider State**: Patches `getAutoTuneToggleState()` to only show ON when `averageGpuClockOffsetMhz > 0`.
5. **Bypasses Background Scan Error**: Intercepts the `-104` error so the UI does not crash with *"Something went wrong"* when toggling tuning.
6. **Clears UI Cache & Restarts Services**: Purges CEF cache and restarts `NvContainerLocalSystem`.

---

### How to Run

#### Option 1: One-Click `.bat` (Recommended)
1. Download [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat) and [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1) into the same folder.
2. Double-click `Fix_NVIDIA_App.bat` (it will automatically request Administrator privileges).

#### Option 2: PowerShell `.ps1`
1. Right-click `Fix_NVIDIA_App.ps1` -> **Run with PowerShell** (or run in an elevated PowerShell terminal):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

---

<a name="русский"></a>
## Русский

### Описание проблемы

Пользователи NVIDIA App часто сталкиваются со следующими проблемами во вкладке **Система -> Производительность -> Автоматическая настройка**:

#### Ошибка 1: Плагин отсутствует / сканирование не начинается
- Переключатель «Автоматическая настройка» нажимается, но процесс висит на 0% либо сразу сбрасывается.
- При переходе на другую вкладку и возврате тумблер сбрасывается в положение **Выкл**.
- В логах отображается `completionStatus: 34` и ошибки связи MessageBus.

#### Ошибка 2: Залипший включенный тумблер (+0 МГц) и невозможность его выключить (v11.0.9+)
- После обновления драйвера или приложения тумблер постоянно горит **Включенным**, но разгон составляет **+0 МГц**.
- При попытке выключить его выскакивает всплывающее уведомление: *«Что-то пошло не так»* (`common.somethingWentWrong`), и тумблер моментально возвращается во включенное состояние.
- Кнопка «Восстановить» недоступна или не реагирует.

#### Ошибка 3: Ошибка фонового сканирования (`-104`) блокирует запуск теста
- При попытке включить авторазгон приложение сразу выдает ошибку *«Что-то пошло не так»*, слайдер не реагирует, и тестирование не начинается.

---

### Технический анализ первопричин

1. **Отсутствие связи плагина в NvContainer**:
   - `nvcontainer.exe` загружает пользовательские плагины из `NvContainer\plugins\User\NVIDIA App` (ссылающегося на `Plugins\localuser`).
   - Установщик размещает плагин авторазгона в `Plugins\oc`, но забывает создать на него junction-ссылку в `Plugins\localuser\oc`.
2. **Логическая ошибка проверки состояния в интерфейсе**:
   - Метод `getAutoTuneToggleState()` в `www\main.*.js` проверял условие `W.stable || 0 === W.type`.
   - Так как `W.stable === 1` даже при нулевом разгоне (+0 МГц), интерфейс ошибочно считал разгон активным и переводил тумблер в положение «ВКЛ».
3. **Сбой фонового сканирования (NvAPI `-104`)**:
   - На новых драйверах (621.14) и архитектурах вызов `NvAPI_GPU_ClientEnableBackgroundOcScanner` возвращает `-104 (NVAPI_NOT_SUPPORTED)`.
   - Интерфейс не перехватывал этот код, вызывая аварийное завершение цепочки вызовов и всплывающее окно ошибки.
4. **Проверка цифровой подписи в NvContainer**:
   - `NvContainer` строго проверяет цифровые сертификаты загружаемых библиотек (`NvcPluginLoadHelper`).
   - Любое изменение байтов в `_OverClockingNvc.dll` нарушает цифровую подпись (`CERT_E_WRONG_USAGE` / Ошибка `2148098064`), из-за чего сервис полностью отказывается загружать модуль.
   - Разрешение администратора (Admin Consent) должно настраиваться штатно через реестр Windows `HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC\<User-SID>`.

> [!NOTE]
> **Ограничение архитектуры (RTX 50-я серия / Blackwell)**:
> В драйвере 621.14 NVIDIA временно отключила автоматическое сканирование кривой V/F (`NvAPI_GPU_ClientStartOcScanner`) на уровне драйвера ядра `nvldkm.sys` для видеокарт Blackwell (`NVAPI_NOT_SUPPORTED: -104`). Ручной разгон ползунками частоты и напряжения в NVIDIA App и MSI Afterburner работает в штатном режиме в ожидании обновлений драйвера.

---

### Что делает скрипт исправления

1. **Создает junction-связь**: Создает NTFS junction `Plugins\localuser\oc` ➔ `Plugins\oc`.
2. **Восстанавливает оригинальную цифровую подпись**: Возвращает оригинальный подписанный файл `_OverClockingNvc.dll` из бэкапа, гарантируя успешную загрузку в NvContainer.
3. **Настраивает Admin Consent в реестре**: Прописывает ключ согласия в `HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC` для всех пользователей системы.
4. **Исправляет логику интерфейса**: Патчит `getAutoTuneToggleState()`, чтобы тумблер отображался включенным только при реальном разгоне `averageGpuClockOffsetMhz > 0`.
5. **Обходит ошибку `-104`**: Исключает сбой *«Что-то пошло не так»* при переключении фонового сканирования.
6. **Очищает кэш UI и перезапускает службы**: Удаляет кэш CEF и перезапускает `NvContainerLocalSystem`.

---

### Инструкция по запуску

#### Вариант 1: Через `.bat` в один клик
1. Скачайте [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat) и [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1) в одну папку.
2. Запустите `Fix_NVIDIA_App.bat` двойным кликом (скрипт автоматически запросит права Администратора).

#### Вариант 2: Через PowerShell `.ps1`
1. Запустите `Fix_NVIDIA_App.ps1` правой кнопкой мыши -> **Выполнить с помощью PowerShell** (или в терминале от имени Администратора):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

---

### Лицензия
Распространяется под лицензией [MIT](LICENSE).
