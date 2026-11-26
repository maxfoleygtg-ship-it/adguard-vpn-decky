<img width="1280" height="640" alt="Без имени" src="https://github.com/user-attachments/assets/05c42330-e1cc-421f-84f2-a443a86f6ac8" />

**[English](#english) · [Русский](#русский)**

## English

You need an AdGuard VPN account and an internet connection.

## Install

1. Switch to Desktop Mode.
2. Download `install-adguard-vpn-decky.sh` and `adguard-vpn-1.1.1.zip` from Releases to your **Downloads** folder.
3. Open **Konsole** and run:
   ```
   bash ~/Downloads/install-adguard-vpn-decky.sh
   ```
4. Choose your system (Bazzite or SteamOS), enter your password (it stays invisible while you type), and answer **y** to every question.
5. Log in to AdGuard using the link the installer shows. You can also log in later with the QR code in the plugin.
6. Go back to Gaming Mode, press **…**, open the plug icon (Decky), and select **AdGuard VPN**.

That's it. Tap a country to connect, or «⛔ Отключить» to disconnect.

## If something is wrong

- The plugin warns you if setup isn't finished or you aren't logged in. Details are in «📜 Журнал» at the bottom of the plugin.
- Running the installer again (step 3) fixes almost everything.
- On SteamOS the `deck` user may have no password. Set one with `passwd`.
- After a major SteamOS update, run the installer again.
- To remove everything: `bash ~/Downloads/install-adguard-vpn-decky.sh --uninstall`

> The plugin interface is in Russian.


## Русский

Нужно: аккаунт AdGuard VPN и интернет.

## Установка

1. Перейдите в режим рабочего стола.
2. Скачайте `install-adguard-vpn-decky.sh` и `adguard-vpn-1.1.1.zip` из Releases в папку **Загрузки**.
3. Откройте **Konsole** и выполните:
   ```
   bash ~/Downloads/install-adguard-vpn-decky.sh
   ```
   Если папка называется по-русски, введите `~/Загрузки/` вместо `~/Downloads/`.
4. Выберите систему (Bazzite или SteamOS), введите пароль (символы не видны, так и должно быть) и на все вопросы отвечайте **y**.
5. Войдите в AdGuard по ссылке, которую покажет установщик. Можно и позже, по QR-коду в самом плагине.
6. Вернитесь в игровой режим, нажмите **…**, откройте значок вилки (Decky) и выберите **AdGuard VPN**.

Готово. Нажмите на страну, чтобы подключиться, или на «⛔ Отключить», чтобы отключиться.

## Если что-то не так

- Плагин сам покажет, если установка не завершена или вы не вошли в аккаунт. Подробности смотрите в «📜 Журнал» внизу плагина.
- Почти всё лечится повторным запуском установщика (шаг 3).
- На SteamOS у пользователя `deck` может не быть пароля. Задайте его командой `passwd`.
- После крупного обновления SteamOS запустите установщик ещё раз.
- Удалить всё: `bash ~/Downloads/install-adguard-vpn-decky.sh --uninstall`

---
<sub>by MaxFoley · сделано с помощью Grok Bot</sub>
