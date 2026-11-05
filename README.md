# NVIDIA App — Automatic Tuning Fix

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20(64--bit)-lightgrey.svg)]()
[![Tested with NVIDIA App](https://img.shields.io/badge/NVIDIA%20App-v11.0.9%2B-green.svg)]()

A lightweight, automated fix for issues with **Automatic Tuning** (GPU auto-overclocking) in **NVIDIA App**:
1. **Toggle resets or fails to start** (0% stuck / immediately unchecks).
2. **Stuck slider / Ghost Tuning** (slider shows ON with +0 MHz, cannot be turned off, throws *"Something went wrong"*).
3. **Scan fails to start when enabling toggle** (throws *"Something went wrong"* due to background OC scan returning NvAPI error `-104` on newer GPUs/drivers like RTX 50-series / 621+).
4. **Scan immediately turns off upon clicking** (`StartOcManualScan` returns `result: false` due to Session 0 isolation in `_OverClockingNvc.dll`).

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

#### Bug 4: Toggle Does Not React / Snaps Back to OFF Immediately
- Clicking the toggle produces no error toast, but the switch immediately flips back to **OFF** without starting the scan.

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
2. On RTX 50-series (Blackwell) and newer drivers (such as 621.14), `NvAPI_GPU_ClientEnableBackgroundOcScanner` returns `-104 (NVAPI_NOT_SUPPORTED)`.
3. Because `enableBackgroundOcScan(!0)` requires driver background scanning to succeed, it throws an error:
   ```
   ERROR nvapp/PerfTuningService Some error occured in EnableBackgroundOcScan [object Object]
   ```
4. This aborts execution before `this.startOcScan()` is ever called, triggers the *"Something went wrong"* popup, and blocks manual OC tuning from starting!

#### Root Cause 4: Session 0 Isolation in `_OverClockingNvc.dll` (`hasAdminConsent`)
1. When `StartOcManualScan` is called, `_OverClockingNvc.dll` verifies admin consent via `hasAdminConsent()` before launching the scan.
2. In `NvAppPermissionHelper.cpp`, `hasAdminConsent()` queries the current session:
   `ProcessIdToSessionId(GetCurrentProcessId(), &sessionId)`
3. Because `_OverClockingNvc.dll` runs inside `NvContainerLocalSystem` (a Windows System service), it executes in **Session 0**.
4. In Windows, Session 0 is non-interactive. Calling `WTSQueryUserToken(0)` or looking up the user token in Session 0 fails with `ERROR_NO_TOKEN` (1008).
5. As a result, `_OverClockingNvc.dll` logs `"We don't have admin consent. Returning false"` and returns `{ "result": false }` to the frontend, even though the interactive user already consented (and `HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC` contains the user's SID)!
6. Seeing `result: false`, the UI executes `Auto tuning disabled manually` and snaps the toggle back to OFF.

---

### What This Fix Does

1. **Restores Missing Plugin**: Creates the NTFS directory junction `Plugins\localuser\oc` ➔ `Plugins\oc` (with automatic fallback copy).
2. **Unlocks Backend Admin Consent**: Patches `hasAdminConsent()` in `_OverClockingNvc.dll` (`E9 DB 47 05 00` ➔ `B0 01 C3 90 90`), bypassing the broken Session 0 user token lookup so `StartOcManualScan` succeeds.
3. **Fixes Stuck Slider Logic**: Patches `getAutoTuneToggleState()` to check `(W.stable && W.averageGpuClockOffsetMhz > 0) || 0 === W.type` so the slider only shows ON when real overclock offsets are applied.
4. **Bypasses Background Scan Failure**:
   - Patches `enableBackgroundOcScan()` so it never throws on `-104`, correctly managing toggle state for both enable and disable actions.
   - Patches `enableBgOcScanAndStartScan()` to directly call `this.startOcScan()`, ensuring manual OC scanning begins immediately via `_OverClockingNvc`.
5. **Cleans UI Cache**: Purges CEF browser cache to apply updated frontend code immediately.
6. **Restarts Services**: Safely restarts `NvContainerLocalSystem` and active NVIDIA App/Overlay processes.

---

### How to Use

#### Method 1: Batch Script (One-Click)
1. Download [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat) and [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1) to the same directory.
2. Double-click `Fix_NVIDIA_App.bat` (it will automatically request Administrator privileges).
3. Follow the on-screen prompts.

#### Method 2: PowerShell
1. Right-click `Fix_NVIDIA_App.ps1` -> **Run with PowerShell** (or run inside an elevated PowerShell terminal):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

---

### Bug Report Status
All identified bugs, root causes, and frontend call chains have been reported to the NVIDIA engineering team via **NVIDIA App Feedback**. Once NVIDIA updates their installer manifest, UI conditional flow, and Session 0 token lookup in an official release, this workaround will no longer be necessary.

---
---

<a name="русский"></a>
## Русский

### Описание проблемы

Пользователи NVIDIA App часто сталкиваются со следующими проблемами во вкладке **Система -> Производительность -> Автоматическая настройка**:

#### Баг 1: Тумблер сразу выключается / разгон не начинается
- При включении тумблера «Автоматическая настройка» ничего не происходит (прогресс висит на 0% или сканирование сбрасывается).
- При переходе на другую вкладку и возвращении тумблер снова выключен.
- В системных логах клиента фиксируются ошибки с кодом `completionStatus: 34`.

#### Баг 2: Слайдер залип во включённом состоянии (+0 МГц) и не выключается (v11.0.9+)
- После обновления драйвера или NVIDIA App тумблер горит **включённым**, но частота разгона равна **+0 МГц** (разгон фактически не работает).
- При попытке нажать на тумблер и выключить его появляется ошибка: *«Что-то пошло не так»* (`common.somethingWentWrong`), и тумблер моментально возвращается во **включённое** состояние.
- Кнопка «Восстановить» неактивна (серая).

#### Баг 3: При включении тумблера сразу ошибка «Что-то пошло не так»
- При нажатии на тумблер автоматической настройки появляется красное уведомление об ошибке, тумблер остаётся выключенным, и тестирование разгона не запускается.

#### Баг 4: Тумблер не реагирует на нажатие (моментально возвращается в выключенное положение)
- При нажатии на тумблер ошибки нет, но тумблер тут же отскакивает обратно в положение «Выкл.», и процесс сканирования не запускается.

---

### Технический разбор причин

#### Причина 1: Пропущенный плагин в инсталляторе
- Фоновый контейнер `nvcontainer.exe` загружает пользовательские плагины из `Plugins\localuser`.
- Библиотека оверклокинга (`_OverClockingNvc.dll`) устанавливается инсталлятором в `Plugins\oc`.
- В манифесте инсталлятора (`NvApp.nvi`) созданы ссылки для всех базовых модулей, но **разработчики забыли добавить создание ссылки для папки `oc`**.
- Контейнер не загружает библиотеку в память, и вызовы падают.

#### Причина 2: Ошибка проверки статуса в интерфейсе
В NVIDIA App 11.0.9 обновился код проверки состояния:
```javascript
getAutoTuneToggleState() {
    return this.scanResultNotification$.pipe(
        (0, c.T)(W => W.stable || 0 === W.type)
    );
}
```
Если разгон ещё не проводился, драйвер возвращает `averageGpuClockOffsetMhz: 0`, но флаг `stable: 1`. Фронтенд видит truthy значение и ошибочно зажигает слайдер при +0 МГц.

#### Причина 3: Блокировка фоновым сканированием (код `-104`)
1. Для запуска разгона интерфейс вызывает цепочку:
   ```javascript
   enableBgOcScanAndStartScan() {
       return this.enableBackgroundOcScan(!0).pipe(
           (0, S.n)(W => W ? this.startOcScan() : ...)
       );
   }
   ```
2. На архитектуре Blackwell (RTX 50-серия) и свежих драйверах (621.xx) вызов фонового сканирования возвращает `-104 (NVAPI_NOT_SUPPORTED)`.
3. Метод `enableBackgroundOcScan` выбрасывает исключение: `Some error occured in EnableBackgroundOcScan`.
4. Из-за этого вызов `this.startOcScan()` **даже не вызывается**, интерфейс показывает сообщение *«Что-то пошло не так»*, а тестирование так и не начинается.

#### Причина 4: Изоляция нулевой сессии в `_OverClockingNvc.dll` (`hasAdminConsent`)
1. При вызове `StartOcManualScan` библиотека `_OverClockingNvc.dll` проверяет согласие администратора через функцию `hasAdminConsent()`.
2. Код `NvAppPermissionHelper.cpp` пытается определить SID пользователя через вызов `WTSQueryUserToken` для текущей сессии процесса.
3. Поскольку `nvcontainer.exe` запущен системной службой `NvContainerLocalSystem`, он работает в **Session 0** (служебная изолированная сессия).
4. В Session 0 нет интерактивного токена пользователя, и вызов завершается ошибкой.
5. Библиотека выводит в лог `"We don't have admin consent. Returning false"` и возвращает `{ "result": false }`, несмотря на то, что пользователь в Session 1 уже дал согласие, и в реестре `HKLM\SOFTWARE\NVIDIA Corporation\Global\NvApp\OC` записан ключ `SID = 1`!
6. Интерфейс, получив `result: false`, логирует `Auto tuning disabled manually` и моментально выключает тумблер.

---

### Что делает скрипт исправления

1. **Восстанавливает плагин**: Создаёт NTFS-связь (junction) `Plugins\localuser\oc` ➔ `Plugins\oc` (или копирует файлы при запрете связей).
2. **Разблокирует проверку прав в бэкенде**: Патчит `hasAdminConsent()` в `_OverClockingNvc.dll` (`E9 DB 47 05 00` ➔ `B0 01 C3 90 90`), обходя сбойную проверку нулевой сессии, благодаря чему `StartOcManualScan` успешно запускает сканирование.
3. **Исправляет отображение слайдера**: Тумблер горит только если действительно применён разгон `averageGpuClockOffsetMhz > 0`.
4. **Разблокирует запуск тестирования**:
   - Перехватывает ошибку `-104`, корректно переключая статус без сбоя в ошибку.
   - Напрямую запускает ручной сканер `startOcScan()`, инициируя процесс автоматического поиска частот.
5. **Очищает кэш UI**: Удаляет кэш CEF для мгновенного применения изменений.
6. **Перезапускает службы**: Перезапускает службу `NvContainerLocalSystem` и закрывает зависшие процессы `NVIDIA App.exe` и `nvcontainer.exe`.

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
