# Aurora Shaders 0.10.1-rc.1 для Horizon

Инструкция для тестового комплекта `Aurora-RC1-source-kit.zip` на macOS.
Внутри лежат четыре файла `.hshader`, изменения исходников Horizon и утилита
для подготовки совместимого клиента. Проверенный API — `0.1-aurora-hdr.1`.
Для сборки нужны Git, инструменты командной строки Xcode, Rust с Cargo,
Python 3 и JDK 25 для подготовки ресурсов Minecraft. Рабочая версия Rust
на машине разработки — 1.96.1.

1. Распакуйте ZIP в новую папку и откройте Terminal в этой папке. Проверьте
   файлы и подготовьте отдельную копию исходников. Утилита загружает
   зафиксированный коммит из репозитория Horizon, применяет патчи по порядку
   и сверяет Git-хеш всего исходного дерева с проверенной сборкой.

   ```sh
   shasum -a 256 -c SHA256SUMS
   python3 tools/prepare-rc-engine.py horizon-aurora
   (cd horizon-aurora && cargo build --locked --profile fast -p horizon-client)
   ```

2. Подготовьте ресурсы из своей копии Minecraft Java 26.3. Запустите эту
   версию один раз в официальном лаунчере. Возьмите соответствующий
   `server.jar` по адресу `downloads.server.url` из файла версии лаунчера.
   В команде укажите путь к своему JAR. Если ресурсы Horizon 26.3 уже
   подготовлены, можно сразу использовать их каталог в следующем шаге.

   ```sh
   (cd horizon-aurora && cargo run --locked --release -p horizon-prepare -- \
     --prepare --server-jar "$HOME/Downloads/server.jar")
   ```

3. Из папки распакованного комплекта создайте тестовый профиль, установите
   пресеты и запустите отдельный творческий мир. При использовании готовых
   ресурсов замените значение `AURORA_RESOURCES` путём к папке с
   `horizon-resources.json`.

   ```sh
   export HORIZON_HOME="$PWD/aurora-test-profile"
   export AURORA_HDR_PIPELINES=1
   AURORA_RESOURCES="$PWD/horizon-aurora/.local/horizon-client/26.3"
   mkdir -p "$HORIZON_HOME/shaderpacks"
   cp packs/*.hshader "$HORIZON_HOME/shaderpacks/"
   ./horizon-aurora/target/fast/horizon-client --resources "$AURORA_RESOURCES" \
     --world "Aurora RC1" --creative --seed 42 --render-distance 8 --width 1280 --height 720
   ```

4. В игре откройте **Options → Horizon Settings → Shader Packs** и выберите
   **Aurora Shaders — Medium (HDR)**. Проверьте, что в терминале появилась
   строка `shader pack aurora_hdr_medium 0.10.1-rc.1`. На Medium лимит отражений
   объектов на воде меняется от 32 шагов в ясный день до 24 при полном дожде.
   Параметры окна задаются в логических единицах. На проверенном Retina-дисплее
   окно 1280×720 даёт кадр 2560×1440.

Если игра уже открыта в сборке с этим API, достаточно скопировать четыре
архива через **Shader Packs → Open Pack Folder** и включить нужный уровень.
Лицензия и уведомления исходного проекта Horizon находятся в `notices/`.
