# NVIDIA App — Automatic Tuning Fix

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011%20(64--bit)-lightgrey.svg)]()
[![Tested with NVIDIA App](https://img.shields.io/badge/NVIDIA%20App-v11.0.9%2B-green.svg)]()

A lightweight, automated fix for the bug in **NVIDIA App** where the **Automatic Tuning** (GPU auto-overclocking) feature fails to start, immediately reverts to disabled, or does nothing when toggled.

---

[English](#english) | [Русский](#русский)

---

<a name="english"></a>
## English

### Problem Description
In **NVIDIA App** under **System -> Performance**, clicking the toggle for **Automatic Tuning**:
1. Briefly checks the toggle, but scanning never begins (progress remains stuck at 0% or does not start).
2. If you switch to another tab and come back, the **Automatic Tuning** toggle is automatically turned back **Off**.
3. In client logs (`%LOCALAPPDATA%\NVIDIA Corporation\NVIDIA App\data\logs\client.log`), you find:
   ```json
   "payload": {
     "completionStatus": 34,
     "confidence": 0,
     "errorType": 1,
     "isTuningProgressRunning": false,
     "lastTestedClocks": 0,
     "percentCompleted": 0
   }
   ```
   and requests to `EnableBackgroundOcScan` fail or time out on the NVIDIA MessageBus.

---

### Root Cause Analysis
During an in-depth diagnosis of the NVIDIA App installation:
- NVIDIA App delegates background hardware management tasks to `nvcontainer.exe`.
- The user-session container looks for plugins in:
  `%ProgramFiles%\NVIDIA Corporation\NvContainer\plugins\User\NVIDIA App`
  which is an NTFS directory junction pointing to:
  `%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\localuser`
- The overclocking plugin (`_OverClockingNvc.dll`) is placed by the installer into:
  `%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\oc`
- **The Bug**: In the NVIDIA installer manifest (`NvApp.nvi`), NVIDIA created directory junctions linking various plugins into `Plugins\localuser` (such as `desktop`, `systeminfo`, `updater`, `downloader`, etc.), but **omitted creating a junction for `oc`**.
- Because this junction is missing, `nvcontainer.exe` never discovers or loads `_OverClockingNvc.dll` into its process memory.
- When the UI sends an `EnableBackgroundOcScan` request, there is no handler listening on the bus, causing the operation to fail immediately with `completionStatus: 34`.

---

### What This Fix Does
1. Automatically creates the missing NTFS directory junction:
   - **Source**: `%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\oc`
   - **Target**: `%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\oc`
   *(Falls back to copying the plugin files if junctions cannot be created).*
2. Gracefully restarts the `NvContainerLocalSystem` service and refreshes user-space `nvcontainer.exe` processes.
3. Upon restart, `nvcontainer.exe` discovers the newly linked `oc` plugin and loads `_OverClockingNvc.dll`.
4. Automatic Tuning is then fully operational!

---

### How to Use

#### Method 1: Batch Script (One-Click)
1. Download [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat).
2. Double-click `Fix_NVIDIA_App.bat` (it will automatically request Administrator privileges).
3. Follow the on-screen instructions.

#### Method 2: PowerShell
1. Download [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1).
2. Right-click `Fix_NVIDIA_App.ps1` -> **Run with PowerShell** (or run inside an elevated PowerShell terminal):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

#### Method 3: Manual Execution (Elevated Command Prompt)
Run the following commands in **Command Prompt (Run as Administrator)**:
```cmd
mklink /J "%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\oc" "%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\oc"
net stop NvContainerLocalSystem
net start NvContainerLocalSystem
taskkill /f /im nvcontainer.exe /fi "SESSION ne 0"
taskkill /f /im "NVIDIA App.exe"
```

---

### Tips for Successful Automatic Tuning Scan
Once the fix is applied, keep in mind:
- **Idle GPU required**: Close any games, 3D software, hardware-accelerated browsers, or Discord before starting the scan. If the GPU clock is under active load, the test will abort.
- **Duration**: The tuning scan runs an algorithmic frequency-voltage curve test and typically takes **10 to 20 minutes**.
- **Display stability**: Minor screen flickering or brief driver resets during the scan are completely normal as the scanner probes the maximum stable voltage/frequency offsets.

---

### Bug Report Status
This bug and its technical root cause have been documented and reported to the NVIDIA engineering team via the **NVIDIA App Feedback** system. Once NVIDIA resolves the missing junction in a future app installer update (`NvApp.nvi`), this manual fix will no longer be required.

---
---

<a name="русский"></a>
## Русский

### Описание проблемы
В **NVIDIA App** на вкладке **Система -> Производительность** при попытке включить тумблер **«Автоматическая настройка»**:
1. Галочка включается на доли секунды, но процесс сканирования и тестирования разгона не начинается.
2. При переходе на любую другую вкладку и возвращении обратно тумблер снова сбрасывается в выключенное состояние.
3. В системных логах клиента (`%LOCALAPPDATA%\NVIDIA Corporation\NVIDIA App\data\logs\client.log`) фиксируются ошибки вида:
   ```json
   "payload": {
     "completionStatus": 34,
     "confidence": 0,
     "errorType": 1,
     "isTuningProgressRunning": false,
     "percentCompleted": 0
   }
   ```
   а вызовы `EnableBackgroundOcScan` завершаются с кодом ошибки (таймаут шины MessageBus).

---

### В чём заключается баг (Технический анализ)
- NVIDIA App использует фоновый сервис `nvcontainer.exe` для исполнения модулей управления видеокартой.
- Пользовательский контейнер загружает плагины из каталога:
  `%ProgramFiles%\NVIDIA Corporation\NvContainer\plugins\User\NVIDIA App`
  который является символьной связью (junction) на:
  `%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\localuser`
- Файлы библиотеки оверклокинга (`_OverClockingNvc.dll`) устанавливаются инсталлятором в:
  `%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\oc`
- **Суть бага**: В установочном манифесте NVIDIA (`NvApp.nvi`) прописано создание ссылок в `Plugins\localuser` для всех модулей (`desktop`, `systeminfo`, `updater`, `downloader` и др.), но **разработчики забыли добавить создание ссылки для папки `oc`**.
- В результате `nvcontainer.exe` просто не знает о существовании `_OverClockingNvc.dll` и не загружает библиотеку в память.
- Интерфейс пытается запустить сканирование, но фоновый модуль отсутствует, из-за чего статус мгновенно сбрасывается на `completionStatus: 34`.

---

### Что делает данный скрипт
1. Создаёт недостающую junction-связь каталога:
   `Plugins\localuser\oc` ➔ `Plugins\oc`
   *(с автоматическим резервным копированием файлов, если создание junction заблокировано).*
2. Перезапускает службу `NvContainerLocalSystem` и закрывает зависшие пользовательские процессы `nvcontainer.exe` и `NVIDIA App.exe`.
3. При следующем запуске `nvcontainer.exe` успешно подхватывает плагин разгона, и автоматическая настройка начинает работать штатно.

---

### Инструкция по запуску

#### Способ 1: Пакетный файл `.bat` (Самый простой)
1. Скачайте [Fix_NVIDIA_App.bat](Fix_NVIDIA_App.bat).
2. Запустите двойным кликом (скрипт сам запросит права Администратора).
3. Дождитесь подтверждения выполнения.

#### Способ 2: PowerShell `.ps1`
1. Скачайте [Fix_NVIDIA_App.ps1](Fix_NVIDIA_App.ps1).
2. Нажмите правой кнопкой мыши -> **Выполнить с помощью PowerShell** (или в консоли PowerShell от имени Администратора):
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Fix_NVIDIA_App.ps1
   ```

#### Способ 3: Вручную через командную строку
Откройте **Командную строку от имени Администратора** и выполните:
```cmd
mklink /J "%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\localuser\oc" "%ProgramFiles%\NVIDIA Corporation\NVIDIA App\Plugins\oc"
net stop NvContainerLocalSystem
net start NvContainerLocalSystem
taskkill /f /im nvcontainer.exe /fi "SESSION ne 0"
taskkill /f /im "NVIDIA App.exe"
```

---

### Рекомендации перед запуском автоматической настройки
- **Закройте фоновые программы**: Перед стартом тестирования закройте игры, бенчмарки, браузеры и плееры с аппаратным ускорением GPU (Discord, Steam, Wallpaper Engine). Видеокарта должна находиться в режиме простоя (Idle).
- **Время тестирования**: Сканирование кривой частот и напряжений занимает в среднем от 10 до 20 минут.
- **Мерцание экрана**: В процессе теста экран может кратковременно моргать или гаснуть на секунду — это нормальное поведение при подборе предельных частот.

---

### Статус обращения в NVIDIA
Подробное описание ошибки и причин её возникновения отправлено разработчикам через встроенную форму обратной связи **NVIDIA App Feedback**. Как только NVIDIA исправит файл манифеста `NvApp.nvi` в очередном обновлении приложения, ручное исправление больше не потребуется.

---

### Лицензия
Данный проект распространяется под лицензией [MIT](LICENSE).
