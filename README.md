# NVIDIA App — Automatic Tuning Fix

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20(64--bit)-lightgrey.svg)]()
[![Tested with NVIDIA App](https://img.shields.io/badge/NVIDIA%20App-v11.0.9%2B-green.svg)]()

A lightweight, automated fix for issues with **Automatic Tuning** (GPU auto-overclocking) in **NVIDIA App**:
1. **Toggle resets or fails to start** (0% stuck / immediately unchecks).
2. **Stuck slider / Ghost Tuning** (slider shows ON with +0 MHz, cannot be turned off, throws *"Something went wrong"*).

---

[English](#english) | [Русский](#русский)

---

<a name="english"></a>
## English

### Problem Description

Users of NVIDIA App frequently encounter one of two major bugs under **System -> Performance -> Automatic Tuning**:

#### Bug 1: Toggle Immediately Turns Off / Scan Never Starts
- When you toggle **Automatic Tuning** ON, nothing happens (progress remains at 0% or scan never starts).
- Switching to another tab and coming back resets the toggle to **Off**.
- Client logs show `completionStatus: 34` and timeouts/missing message handlers on the NVIDIA MessageBus.

#### Bug 2: Stuck Slider ON (+0 MHz) and Cannot Be Turned Off (v11.0.9+)
- After app or driver updates, the **Automatic Tuning** toggle appears permanently **ON**, but the GPU clock offset is **+0 MHz** (no overclock is active).
- Clicking the toggle to turn it **Off** results in a toast error: *"Something went wrong"* (`common.somethingWentWrong`), and the toggle immediately snaps back to **ON**.
- The "Restore" button is greyed out/disabled.

---

### Technical Root Cause Analysis

#### Root Cause of Bug 1: Missing Plugin Junction
- NVIDIA App delegates background GPU management to `nvcontainer.exe`.
- The container discovers plugins via `%ProgramFiles%\NVIDIA Corporation\NvContainer\plugins\User\NVIDIA App`, which points to `Plugins\localuser`.
- The overclocking plugin (`_OverClockingNvc.dll`) is placed by the installer into `Plugins\oc`.
- In the installer manifest (`NvApp.nvi`), NVIDIA configured junctions for most plugins (desktop, systeminfo, updater, etc.), but **omitted creating a junction for `oc`**.
- As a result, `nvcontainer.exe` never loads `_OverClockingNvc.dll` into memory, causing any `EnableBackgroundOcScan` call to fail silently.

#### Root Cause of Bug 2: Frontend State Logic Flaw & NvAPI `-104` Error
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
4. When the user clicks the toggle to turn it OFF, the app calls `EnableBackgroundOcScan({ enable: false })`.
5. On modern architectures (such as RTX 50-series / Blackwell) and newer drivers (e.g., 621.14), NvAPI returns `-104 (NVAPI_NOT_SUPPORTED)`.
6. The UI catches this error, shows the *"Something went wrong"* popup, and executes `this.tuningToggleRef().checked = this.autoTunerToggleState`, forcing the toggle back to **ON**!

---

### What This Fix Does

1. **Restores Missing Plugin**: Creates the NTFS directory junction `Plugins\localuser\oc` ➔ `Plugins\oc` (with automatic fallback copy).
2. **Fixes Stuck Slider Logic**: Patches `www\main.*.js` (with automatic `.bak` backup):
   - Corrects `getAutoTuneToggleState()` to check `(W.stable && W.averageGpuClockOffsetMhz > 0) || 0 === W.type` so the slider only shows ON when real overclock offsets are applied.
   - Updates `enableBackgroundOcScan()` to treat disabling as successful even if the driver returns `-104`, allowing the user to cleanly turn off Automatic Tuning without errors.
3. **Cleans UI Cache**: Purges CEF browser cache to apply updated frontend code immediately.
4. **Restarts Services**: Safely restarts `NvContainerLocalSystem` and active NVIDIA App/Overlay processes.

---

### How to Use

#### Method 1: Batch Script (One-Click)
1. Download [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat).
2. Double-click `Fix_NVIDIA_App.bat` (it will automatically request Administrator privileges).
3. Follow the on-screen prompts.

#### Method 2: PowerShell
1. Download [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1).
2. Right-click `Fix_NVIDIA_App.ps1` -> **Run with PowerShell** (or run inside an elevated PowerShell terminal):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

---

### Bug Report Status
Both bugs and their exact lines of failure have been reported to the NVIDIA engineering team via **NVIDIA App Feedback**. Once NVIDIA resolves the installer manifest and UI conditional check in an official update, this fix will no longer be necessary.

---
---

<a name="русский"></a>
## Русский

### Описание проблемы

Пользователи NVIDIA App часто сталкиваются с одной из двух проблем во вкладке **Система -> Производительность -> Автоматическая настройка**:

#### Баг 1: Тумблер сразу выключается / разгон не начинается
- При включении тумблера «Автоматическая настройка» ничего не происходит (прогресс висит на 0% или сканирование сбрасывается).
- При переходе на другую вкладку и возвращении тумблер снова выключен.
- В системных логах клиента фиксируются ошибки с кодом `completionStatus: 34`.

#### Баг 2: Слайдер залип во включённом состоянии (+0 МГц) и не выключается (v11.0.9+)
- После обновления драйвера или NVIDIA App тумблер горит **включённым**, но частота разгона равна **+0 МГц** (разгон фактически не работает).
- При попытке нажать на тумблер и выключить его появляется ошибка: *«Что-то пошло не так»* (`common.somethingWentWrong`), и тумблер моментально возвращается во **включённое** состояние.
- Кнопка «Восстановить» неактивна (серая).

---

### Технический разбор причин

#### Причина бага 1: Пропущенный плагин в инсталляторе
- Фоновый контейнер `nvcontainer.exe` загружает пользовательские плагины из `Plugins\localuser`.
- Библиотека оверклокинга (`_OverClockingNvc.dll`) устанавливается инсталлятором в `Plugins\oc`.
- В файле манифеста инсталлятора (`NvApp.nvi`) созданы ссылки для всех базовых модулей, но **разработчики забыли добавить создание ссылки для папки `oc`**.
- Контейнер не загружает библиотеку в память, и вызовы `EnableBackgroundOcScan` падают.

#### Причина бага 2: Ошибка в логике фронтенда и код `-104` от NvAPI
В обновлении NVIDIA App 11.0.9 появился нативный плагин `CEF\plugins\NVIDIA App\NvOc.dll` и обновился фронтенд:
1. При загрузке страницы статус тумблера запрашивается через `getAutoTuneToggleState()` в `www\main.*.js`:
   ```javascript
   getAutoTuneToggleState() {
       return this.scanResultNotification$.pipe(
           (0, c.T)(W => W.stable || 0 === W.type)
       );
   }
   ```
2. Если сканирование не завершилось успехом, драйвер возвращает `completionStatus: 34`, смещение `+0 МГц`, но флаг `stable: 1` (базовые частоты стабильны).
3. Так как `W.stable` равен `1` (truthy), интерфейс ошибочно решает, что автоматическая настройка **включена**, и зажигает тумблер при +0 МГц!
4. Когда пользователь кликает по тумблеру для выключения, приложение вызывает `EnableBackgroundOcScan({ enable: false })`.
5. На видеокартах нового поколения (например, RTX 50-серии / Blackwell) и свежих драйверах (621.xx) драйвер возвращает `-104 (NVAPI_NOT_SUPPORTED)`.
6. Обработчик ошибок перехватывает этот код, показывает всплывающее окно *«Что-то пошло не так»* и возвращает тумблер в исходное состояние `checked = true`. Тумблер оказывается заблокирован.

---

### Что делает скрипт исправления

1. **Восстанавливает плагин**: Создаёт NTFS-связь (junction) `Plugins\localuser\oc` ➔ `Plugins\oc` (или копирует файлы при запрете связей).
2. **Исправляет логику интерфейса**: Патчит `www\main.*.js` (с созданием резервной копии `.bak`):
   - Исправляет проверку статуса: тумблер зажигается только при реальном разгоне `averageGpuClockOffsetMhz > 0`.
   - Разрешает отключение тумблера без падения в ошибку, если драйвер вернул `-104`.
3. **Очищает кэш UI**: Удаляет кэш CEF для мгновенного применения обновлённого скрипта.
4. **Перезапускает службы**: Перезапускает службу `NvContainerLocalSystem` и закрывает зависшие процессы `NVIDIA App.exe` и `nvcontainer.exe`.

---

### Инструкция по запуску

#### Вариант 1: Через `.bat` в один клик
1. Скачайте [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat).
2. Запустите двойным кликом (скрипт автоматически запросит права Администратора).

#### Вариант 2: Через PowerShell `.ps1`
1. Скачайте [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1).
2. Запустите правой кнопкой мыши -> **Выполнить с помощью PowerShell** (или в терминале от имени Администратора):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

---

### Лицензия
Распространяется под лицензией [MIT](LICENSE).
