import os, sys, time, json, yaml, threading, requests, psutil
from utils.monitors import ResourceMonitor, StateStore
from utils.remediator import AutoRemediator
from utils.fail2ban import available as f2b_available, status as f2b_status
from utils.cloudflare import CF
from utils.prom_exporter import Exporter

API_BASE = "https://api.telegram.org/bot{token}/{method}"
API_BASE = "https://api.telegram.org/bot{token}/{method}"
OFFSET_FILE = "/opt/vps-guardian/.tg_offset"   # << baru

class SimpleBot:
    def __init__(self, token: str, chat_id: str, polling_interval=2):
        self.token = token; self.chat_id = str(chat_id)
        self.offset = None; self.polling_interval = polling_interval
        self.cb_handlers = []; self.cmd_handlers = {}; self._stop = False
                # restore offset terakhir agar tidak memproses ulang update lama
        try:
            self.offset = int(open(OFFSET_FILE, "r").read().strip())
        except Exception:
            pass
    def send_message(self, text: str, buttons=None, chat_id=None):
        chat_id = chat_id or self.chat_id
        payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
        if buttons:
            ik = [[{"text": t, "callback_data": d}] for t,d in buttons]
            payload["reply_markup"] = json.dumps({"inline_keyboard": ik})
        url = API_BASE.format(token=self.token, method="sendMessage")
        try: requests.post(url, data=payload, timeout=10)
        except Exception: pass
    def send_menu(self, rows, chat_id=None):
        chat_id = chat_id or self.chat_id
        reply_markup = {"keyboard": [[{"text": t} for t in row] for row in rows], "resize_keyboard": True, "is_persistent": True}
        url = API_BASE.format(token=self.token, method="sendMessage")
        payload = {"chat_id": chat_id, "text": "📋 Menu cepat:", "parse_mode": "HTML", "reply_markup": json.dumps(reply_markup)}
        try: requests.post(url, data=payload, timeout=10)
        except Exception: pass
    def answer_callback(self, cb_id: str, text: str):
        url = API_BASE.format(token=self.token, method="answerCallbackQuery")
        try: requests.post(url, data={"callback_query_id": cb_id, "text": text, "show_alert": False}, timeout=10)
        except Exception: pass
    def on_callback(self, prefix: str, handler): self.cb_handlers.append((prefix, handler))
    def on_command(self, text: str, handler): self.cmd_handlers[text] = handler
    def start_polling(self): threading.Thread(target=self._poll_loop, daemon=True).start()
    def _poll_loop(self):
        while not self._stop:
            try:
                params={"timeout":15}
                if self.offset is not None: params["offset"]=self.offset
                url = API_BASE.format(token=self.token, method="getUpdates")
                r = requests.get(url, params=params, timeout=20)
                if not r.ok: time.sleep(self.polling_interval); continue
                for upd in r.json().get("result", []):
                    self.offset = upd["update_id"] + 1
                                        # persist offset ke disk (anti-loop saat restart)
                    try:
                        open(OFFSET_FILE, "w").write(str(self.offset))
                    except Exception:
                        pass
                    if "callback_query" in upd:
                        cb = upd["callback_query"]; data = cb.get("data","")
                        if cb.get("message",{}).get("chat",{}).get("id") != int(self.chat_id): continue
                        for pref, handler in self.cb_handlers:
                            if data.startswith(pref):
                                try: handler(cb.get("id"), {"data": data})
                                except Exception: pass
                        continue
                    msg = upd.get("message") or {}; chat = msg.get("chat",{})
                    if not chat: continue
                    if str(chat.get("id")) != self.chat_id: continue
                    text = (msg.get("text") or "").strip()
                    if not text: continue
                    handler = self.cmd_handlers.get(text)
                    if handler:
                        try: handler()
                        except Exception: pass
                        continue
                    mapping = {"📊 Status":"/status","🧪 Self-test":"/selftest","🚫 Blocked":"/blocked","🔁 Restart Agent":"/restart_agent","🛡 Fail2ban":"/f2b_status","☁️ Cloudflare":"/cf_status","📋 Menu":"/menu"}
                    if text in mapping and mapping[text] in self.cmd_handlers:
                        try: self.cmd_handlers[mapping[text]]()
                        except Exception: pass
                        continue
                    if text in self.cmd_handlers:
                        try: self.cmd_handlers[text]()
                        except Exception: pass
            except Exception:
                time.sleep(self.polling_interval)

def load_cfg():
    with open("/opt/vps-guardian/config.yaml","r",encoding="utf-8") as f:
        return yaml.safe_load(f)

def main():
    cfg = load_cfg()
    token = cfg["telegram"]["bot_token"]; chat_id = str(cfg["telegram"]["chat_id"])
    polling_interval = int(cfg["telegram"].get("polling_interval", 2))

    if cfg.get("prometheus", {}).get("enable", False):
        Exporter(cfg["prometheus"]["bind"], int(cfg["prometheus"]["port"])).start()

    bot = SimpleBot(token, chat_id, polling_interval=polling_interval)
    def notify(msg: str, buttons=None): bot.send_message(f"<b>[VPS Guardian]</b> {msg}", buttons=buttons)

    MENU_ROWS = [["📊 Status","🧪 Self-test"],["🚫 Blocked","🔁 Restart Agent"],["🛡 Fail2ban","☁️ Cloudflare"],["📋 Menu"]]

    import psutil, os
    def cmd_menu(): bot.send_menu(MENU_ROWS)
    def cmd_status():
        cpu=psutil.cpu_percent(); mem=psutil.virtual_memory().percent; disk=psutil.disk_usage('/').percent
        load=(os.getloadavg()[0]/(os.cpu_count() or 1)) if hasattr(os,"getloadavg") else 0.0
        notify(f"Status: CPU {cpu:.1f}%, Mem {mem:.1f}%, Disk {disk:.1f}%, Load {load:.2f}/core")
    def cmd_selftest(): notify("✅ Self-test OK")
        def cmd_restart_agent():
        notify("🔁 Restarting agent...")
        # delay 1s agar offset tersimpan & ack lebih dulu
        os.system('nohup bash -c "sleep 1; systemctl restart vps-guardian" >/dev/null 2>&1 &')
    def cmd_blocked():
        st=StateStore(cfg["state"]["file"]); ips=list(st.state.get("blocked_ips", {}).keys()); notify("Blocked IPs: "+(", ".join(ips) if ips else "-"))
    def cmd_f2b_status():
        if not f2b_available(): notify("Fail2ban not installed/available."); return
        notify("<b>Fail2ban</b>\\n<pre>"+f2b_status()+"</pre>")
    def cmd_cf_status():
        cfc=cfg.get("cloudflare", {})
        if not cfc.get("enable", False): notify("Cloudflare integration disabled."); return
        cf=CF(cfc.get("api_token",""), cfc.get("zone_id","")); notify(cf.status())

    for name, func in {"/menu":cmd_menu,"/status":cmd_status,"/selftest":cmd_selftest,"/restart_agent":cmd_restart_agent,"/blocked":cmd_blocked,"/f2b_status":cmd_f2b_status,"/cf_status":cmd_cf_status}.items():
        bot.on_command(name, func)
    bot.on_command("📋 Menu", cmd_menu); bot.on_command("📊 Status", cmd_status); bot.on_command("🧪 Self-test", cmd_selftest)
    bot.on_command("🚫 Blocked", cmd_blocked); bot.on_command("🔁 Restart Agent", cmd_restart_agent); bot.on_command("🛡 Fail2ban", cmd_f2b_status); bot.on_command("☁️ Cloudflare", cmd_cf_status)

    # Inline callback: quick actions restart
    def on_qa_restart(cb_id, payload):
        data=payload["data"]
        try: _,_,svc=data.split(":",2)
        except Exception: bot.answer_callback(cb_id,"Bad data"); return
               bot.answer_callback(cb_id, f"Restart {svc} dikirim")
        os.system(f'nohup bash -c "sleep 1; systemctl restart {svc}" >/dev/null 2>&1 &')
        notify(...)
    bot.on_callback("qa:restart:", on_qa_restart)

    bot.start_polling()

    ResourceMonitor(cfg, notify).start()
    AutoRemediator(cfg, notify).start()

    bot.send_menu(MENU_ROWS)
    while True: time.sleep(60)

if __name__ == "__main__":
    main()
