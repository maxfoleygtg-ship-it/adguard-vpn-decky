# AdGuard VPN for Steam Deck / Bazzite (Decky)

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

---
<sub>by MaxFoley · made with Grok Bot</sub>
