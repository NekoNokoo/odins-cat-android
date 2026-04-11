# Odin's Cat 0.6.2

`0.6.2` закрепляет `Yandex camo` как основной Android-first whitelist-facing путь.

Что меняется:
- основной пользовательский путь через `Yandex edge` теперь опирается на живой `device -> Yandex :443 -> xhttp -> VPS` контур;
- `ya.ru`-ish first hop закреплён как основной `cdnAntiWhitelist` runtime для новых access/invite профилей;
- импортированный `camo`-профиль больше не должен визуально сваливаться в старый proxy-only Yandex flow;
- быстрый путь через `62-84-123-148.sslip.io` остаётся запасным fallback-артефактом для диагностики и отката.

Проверено перед релизом:
- Android VPN поднимается как системный TUN;
- `xray-native` стартует с `transport = xhttp`;
- Yandex edge принимает реальный first hop на `:443`;
- origin получает живой трафик после Yandex hop;
- `ya.ru`-ish `SNI/Host` path работает в живом сеансе.

Важно:
- текущий `camo` использует `tlsAllowInsecure = true`, то есть это camouflage path, а не настоящий сертификат `ya.ru`;
- для реальных сетей с белыми списками этот режим нужно подтверждать полевыми прогонами отдельно.
