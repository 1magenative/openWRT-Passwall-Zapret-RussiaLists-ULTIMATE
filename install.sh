#!/bin/sh

echo "=========================================================="
echo "  Установка умной маршрутизации YouTube (Zapret + Passwall) "
echo "=========================================================="

# 1. Создаем правильную стратегию Zapret (которая пробивает ТСПУ на всех устройствах)
echo "[1/5] Настройка ядра Zapret..."
mkdir -p /opt/zapret
cat << 'EOF' > /opt/zapret/config
FWTYPE=iptables
INIT_APPLY_FW=1
DISABLE_IPV6=1
MODE=nfqws
MODE_HTTP=1
MODE_HTTP_KEEPALIVE=0
MODE_HTTPS=1
MODE_QUIC=1
MODE_FILTER=none
DESYNC_MARK=0x40000000
DESYNC_MARK_POSTNAT=0x20000000
NFQWS_OPT_DESYNC="--wsize=33 --wssize=1:6"

NFQWS_OPT="
--filter-tcp=80 --dpi-desync=fake,multisplit --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig <HOSTLIST> --new
--filter-tcp=443 --dpi-desync=multidisorder --dpi-desync-split-pos=1,host+2,midsld+2,midsld+5,sniext+1,sniext+2,endhost-2 --dpi-desync-split-seqovl=1 --dpi-desync-ttl=3 <HOSTLIST> --new
--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 <HOSTLIST> --new
"
EOF

# 2. Создаем списки доменов для Zapret
echo "[2/5] Обновление списков доменов YouTube..."
mkdir -p /opt/zapret/ipset
cat << 'EOF' > /opt/zapret/ipset/zapret-hosts-user.txt
youtube.com
googlevideo.com
ytimg.com
youtu.be
ggpht.com
youtubei.googleapis.com
yt3.ggpht.com
ytimg.l.google.com
googleapis.com
gvt1.com
redirector.googlevideo.com
s.youtube.com
EOF

# 3. Настройка маршрутизации Passwall (Direct RUSSIA и Proxy) через UCI
echo "[3/5] Интеграция с Passwall (создание правил RUSSIA)..."
# Удаляем старые правила, если они были, чтобы не плодить дубли
uci -q delete passwall.Direct
uci -q delete passwall.Proxy

# Создаем RUSSIA (Direct)
uci set passwall.Direct=shunt_rules
uci set passwall.Direct.remarks='RUSSIA'
uci set passwall.Direct.network='tcp,udp'
uci add_list passwall.Direct.domain_list='geosite:category-ru'
uci add_list passwall.Direct.domain_list='geosite:tld-ru'
uci add_list passwall.Direct.domain_list='domain:su'
uci add_list passwall.Direct.domain_list='domain:xn--p1ai'

# Создаем пустое правило Proxy для будущих доменов
uci set passwall.Proxy=shunt_rules
uci set passwall.Proxy.remarks='Proxy'
uci set passwall.Proxy.network='tcp,udp'
uci commit passwall

# 4. Установка умной панели управления в LuCI
echo "[4/5] Установка кастомного Web-интерфейса LuCI..."
mkdir -p /usr/lib/lua/luci/view/passwall
cat << 'EOF' > /usr/lib/lua/luci/view/passwall/zapret.htm
<%+header%>
<%
local sys = require "luci.sys"
local fs = require "nixio.fs"
local http = require "luci.http"
local disp = require "luci.dispatcher"
local uci = require "luci.model.uci".cursor()

local conf_file = "/opt/zapret/config"
local my_url = disp.build_url("admin/services/passwall/zapret")

local yt_domains = {
    "youtube.com", "googlevideo.com", "ytimg.com", "youtu.be",
    "ggpht.com", "youtubei.googleapis.com", "yt3.ggpht.com",
    "ytimg.l.google.com", "googleapis.com", "gvt1.com",
    "redirector.googlevideo.com", "s.youtube.com"
}

local function remove_domains(domain_str)
    if not domain_str or domain_str == "" then return "" end
    local lines = {}
    for line in domain_str:gmatch("[^\r\n]+") do
        local is_yt = false
        for _, yt in ipairs(yt_domains) do
            if line == yt then is_yt = true; break end
        end
        if not is_yt then table.insert(lines, line) end
    end
    return table.concat(lines, "\n")
end

local function add_domains(domain_str)
    local clean_str = remove_domains(domain_str)
    if clean_str ~= "" then return clean_str .. "\n" .. table.concat(yt_domains, "\n") else return table.concat(yt_domains, "\n") end
end

local function execute_bg(action_type)
    local dl_direct = uci:get("passwall", "Direct", "domain_list") or ""
    local dl_proxy = uci:get("passwall", "Proxy", "domain_list") or ""

    if action_type == "stop" then
        dl_direct = remove_domains(dl_direct)
        dl_proxy = add_domains(dl_proxy)
    else
        dl_proxy = remove_domains(dl_proxy)
        dl_direct = add_domains(dl_direct)
    end

    uci:set("passwall", "Direct", "domain_list", dl_direct)
    uci:set("passwall", "Proxy", "domain_list", dl_proxy)
    uci:commit("passwall")

    local script_content = "#!/bin/sh\n"
    if action_type == "stop" then
        script_content = script_content .. "/etc/init.d/zapret stop\n/etc/init.d/passwall restart\n"
    else
        script_content = script_content .. "/etc/init.d/zapret " .. action_type .. "\n/etc/init.d/passwall restart\n"
    end
    fs.writefile("/tmp/zapret_toggle.sh", script_content)
    sys.call("chmod +x /tmp/zapret_toggle.sh && (sleep 1; /tmp/zapret_toggle.sh) >/dev/null 2>&1 &")
end

local action = http.formvalue("action")
if action == "start" or action == "stop" or action == "restart" then 
    execute_bg(action)
    http.redirect(my_url .. "?wait=1")
    return
end

if http.formvalue("save") then
    local new_opt = http.formvalue("nfqws_opt") or ""
    local clean_opt = new_opt:gsub("\r", "")
    sys.call("sed -i '/^NFQWS_OPT=/d' " .. conf_file)
    sys.call("sed -i '/^--filter-/d' " .. conf_file)
    sys.call("sed -i '/^\"$/d' " .. conf_file)
    local append_str = '\nNFQWS_OPT="\n' .. clean_opt .. '\n"\n'
    local f = io.open(conf_file, "a")
    if f then f:write(append_str); f:close() end
    execute_bg("restart")
    http.redirect(my_url .. "?wait=1")
    return
end

local is_running = sys.call("pgrep nfqws >/dev/null") == 0
local current_conf = fs.readfile(conf_file) or ""
local current_opt = current_conf:match('\nNFQWS_OPT="([^"]*)"') 
if not current_opt then current_opt = current_conf:match('^NFQWS_OPT="([^"]*)"') end
if current_opt then current_opt = current_opt:gsub("^%s+", ""):gsub("%s+$", "") else current_opt = "" end
%>
<div class="cbi-map">
    <h2 class="section-title">Zapret - Управление и маршрутизация</h2>
    <div class="cbi-section">
        <div class="cbi-section-node">
            <div class="cbi-value">
                <label class="cbi-value-title">Статус системы</label>
                <div class="cbi-value-field">
                    <% if http.formvalue("wait") == "1" then %>
                        <span style="color:#d97706; font-weight:bold;">⏳ ПРИМЕНЕНИЕ (Passwall настраивает маршруты, ждите)...</span>
                    <% elseif is_running then %>
                        <span style="color:green; font-weight:bold;">✔ ЗАПУЩЕН (YouTube идет через Zapret в обход VPN)</span>
                    <% else %>
                        <span style="color:red; font-weight:bold;">✘ ОСТАНОВЛЕН (YouTube завернут в VPN)</span>
                    <% end %>
                </div>
            </div>
            <div class="cbi-value">
                <label class="cbi-value-title">Управление</label>
                <div class="cbi-value-field">
                    <form style="display:inline;" method="post" action="<%=my_url%>"><input type="hidden" name="action" value="start" /><input type="submit" class="cbi-button cbi-button-apply z-btn" value="Запустить" /></form>
                    <form style="display:inline;" method="post" action="<%=my_url%>"><input type="hidden" name="action" value="stop" /><input type="submit" class="cbi-button cbi-button-remove z-btn" value="Остановить" /></form>
                    <form style="display:inline;" method="post" action="<%=my_url%>"><input type="hidden" name="action" value="restart" /><input type="submit" class="cbi-button cbi-button-reload z-btn" value="Перезапустить" /></form>
                </div>
            </div>
            <form method="post" action="<%=my_url%>">
                <div class="cbi-value">
                    <label class="cbi-value-title">Стратегия NFQWS_OPT</label>
                    <div class="cbi-value-field">
                        <textarea class="cbi-input-textarea" name="nfqws_opt" rows="6" style="width:100%; font-family:monospace; margin-bottom:10px;"><%=current_opt%></textarea><br /><small>Вставляйте стратегию как есть (БЕЗ кавычек). Роутер сам всё правильно экранирует и сохранит!</small>
                    </div>
                </div>
                <div class="cbi-submit-buttons" style="margin-top: 15px;"><input type="submit" name="save" class="cbi-button cbi-button-save z-btn" value="Сохранить и применить" /></div>
            </form>
        </div>
    </div>
</div>
<% if http.formvalue("wait") == "1" then %>
<script type="text/javascript">
    var btns = document.querySelectorAll('.z-btn');
    for (var i = 0; i < btns.length; i++) { btns[i].disabled = true; btns[i].style.opacity = '0.5'; }
    setTimeout(function() { window.location.href = '<%=my_url%>'; }, 10000);
</script>
<% end %>
<%+footer%>
EOF

# 5. Отключение IPv6 на уровне DNS (Критично для Apple/Android)
echo "[5/5] Блокировка утечек IPv6..."
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 6. Запуск и применение
echo "Перезапуск сервисов..."
/etc/init.d/zapret restart
/etc/init.d/passwall restart

echo "=========================================================="
echo " УСТАНОВКА ЗАВЕРШЕНА! "
echo " Зайдите в меню роутера: Services -> Passwall -> Zapret Settings"
echo "=========================================================="