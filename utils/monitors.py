import os, time, re, json, psutil, threading, subprocess, signal
from typing import Dict, Any, List, Tuple
from .firewall import block_ip as fw_block, unblock_ip as fw_unblock
from .fail2ban import available as f2b_available, banip as f2b_ban, unbanip as f2b_unban
from .prom_exporter import set_metric

def now_ts(): return int(time.time())

class StateStore:
    def __init__(self, path: str):
        self.path=path; self.state={"blocked_ips": {}, "ssh_failures": {}, "approvals": {}}
        self._load()
    def _load(self):
        try:
            if os.path.exists(self.path):
                with open(self.path,"r") as f: self.state=json.load(f)
        except Exception: pass
    def save(self):
        tmp=self.path+".tmp"
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(tmp,"w") as f: json.dump(self.state,f,indent=2)
            os.replace(tmp,self.path)
        except Exception: pass

class ResourceMonitor(threading.Thread):
    def __init__(self, cfg: Dict[str, Any], notifier):
        super().__init__(daemon=True); self.cfg=cfg; self.notifier=notifier; self.cooldowns={}; self.nproc=os.cpu_count() or 1
    def sample_top(self, sample_sec: float = 0.4) -> Tuple[List[Tuple[str,int,float]], List[Tuple[str,int,int]]]:
        try:
            for p in psutil.process_iter(attrs=["pid","name"]):
                try: p.cpu_percent(None)
                except Exception: pass
            time.sleep(sample_sec)
            cpu_list=[]; mem_list=[]
            for p in psutil.process_iter(attrs=["pid","name"]):
                try:
                    name=p.info.get("name") or "proc"; pid=p.info["pid"]; cpu=p.cpu_percent(None); rss=p.memory_info().rss
                    cpu_list.append((name,pid,cpu)); mem_list.append((name,pid,rss))
                except Exception: pass
            cpu_list.sort(key=lambda x: x[2], reverse=True); mem_list.sort(key=lambda x: x[2], reverse=True)
            return cpu_list[:3], mem_list[:3]
        except Exception: return [], []
    def build_buttons(self, offenders: List[str]):
        qa=self.cfg.get("quick_actions", {})
        if not qa or not qa.get("enable", False): return None
        mapping=qa.get("restart_services", {}) or {}; maxb=int(qa.get("max_buttons",3))
        found=[]; lower_off=[o.lower() for o in offenders]
        for svc, pats in mapping.items():
            for pat in pats:
                if any(pat.lower() in o for o in lower_off): found.append(svc); break
            if len(found)>=maxb: break
        if not found: return None
        return tuple((f"🔁 Restart {svc}", f"qa:restart:{svc}") for svc in found)
    def run(self):
        interval=self.cfg["monitoring"]["interval"]; th_cpu=self.cfg["monitoring"]["cpu_threshold"]; th_mem=self.cfg["monitoring"]["mem_threshold"]; th_disk=self.cfg["monitoring"]["disk_threshold"]; th_load=self.cfg["monitoring"]["load_threshold"]; cooldown=self.cfg["monitoring"]["notify_cooldown_seconds"]
        while True:
            try:
                cpu=psutil.cpu_percent(interval=None); mem=psutil.virtual_memory().percent; disk=psutil.disk_usage('/').percent
                try: lavg=os.getloadavg()[0]
                except Exception: lavg=0.0
                lavg_per_core=lavg/(self.nproc or 1)
                set_metric("cpu",cpu); set_metric("mem",mem); set_metric("disk",disk); set_metric("load_per_core",lavg_per_core); set_metric("processes",len(psutil.pids()))
                def maybe_notify(key, msg_base):
                    last=self.cooldowns.get(key,0)
                    if now_ts()-last<cooldown: return
                    top_cpu, top_mem=self.sample_top()
                    offenders=[]
                    if top_cpu: offenders += [n for n,_,__ in top_cpu]
                    if top_mem: offenders += [n for n,_,__ in top_mem]
                    cpu_txt=", ".join([f"{n}({pid}) {c:.0f}%" for n,pid,c in top_cpu]) or "-"
                    mem_txt=", ".join([f"{n}({pid}) {m/1048576:.0f}MB" for n,pid,m in top_mem]) or "-"
                    swap=psutil.swap_memory()
                    detail=f"\n• Top CPU: {cpu_txt}\n• Top Mem: {mem_txt}\n• Swap: {swap.used/1048576:.0f}MB used"
                    buttons=self.build_buttons(offenders)
                    self.cooldowns[key]=now_ts(); self.notifier(msg_base+detail, buttons=buttons)
                if cpu>=th_cpu:  maybe_notify("cpu",  f"⚠️ CPU tinggi {cpu:.1f}% (≥ {th_cpu}%)")
                if mem>=th_mem:  maybe_notify("mem",  f"⚠️ Memori tinggi {mem:.1f}% (≥ {th_mem}%)")
                if disk>=th_disk: maybe_notify("disk", f"⚠️ Disk penuh {disk:.1f}% (≥ {th_disk}%)")
                if lavg_per_core>=th_load: maybe_notify("load", f"⚠️ Load tinggi {lavg_per_core:.2f}/core (≥ {th_load:.2f})")
                time.sleep(interval)
            except Exception: time.sleep(interval)
