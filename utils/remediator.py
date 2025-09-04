import threading, time, psutil, subprocess, os
class AutoRemediator(threading.Thread):
    def __init__(self, cfg, notify):
        super().__init__(daemon=True); self.cfg=cfg; self.notify=notify
    def run(self):
        aa=self.cfg.get("auto_actions", {})
        if not aa or not aa.get("enable", False): return
        mem_cfg=aa.get("memory", {})
        threshold=int(mem_cfg.get("threshold", 90)); sustain=int(mem_cfg.get("sustain_seconds", 120))
        restart_services=mem_cfg.get("restart_services", [])
        kill_top=int(mem_cfg.get("kill_top_consumers", 0))
        exclude=set(mem_cfg.get("exclude_names", ["mysqld","postgres","dockerd","containerd","systemd-journald"]))
        add_swap=bool(aa.get("add_swap_when_none", False)); swap_gb=int(aa.get("swap_size_gb", 2))
        high_since=None
        while True:
            try:
                mem=psutil.virtual_memory()
                if mem.percent>=threshold:
                    high_since=high_since or time.time()
                    if time.time()-high_since>=sustain:
                        if add_swap:
                            r=subprocess.run(["swapon","--show","--noheading"], capture_output=True, text=True)
                            if r.returncode==0 and not r.stdout.strip():
                                subprocess.run(["fallocate","-l",f"{swap_gb}G","/swapfile"], check=False)
                                subprocess.run(["chmod","600","/swapfile"], check=False)
                                subprocess.run(["mkswap","/swapfile"], check=False)
                                subprocess.run(["swapon","/swapfile"], check=False)
                                try:
                                    with open("/etc/fstab","a") as f: f.write("/swapfile none swap sw 0 0\n")
                                except Exception: pass
                                self.notify(f"🧩 AutoRemediator: swap {swap_gb}G dibuat & diaktifkan.")
                        for svc in restart_services:
                            subprocess.run(["systemctl","restart",svc], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            self.notify(f"🔁 AutoRemediator: restart service {svc}.")
                        if kill_top>0:
                            procs=[]
                            for p in psutil.process_iter(attrs=["name","pid","memory_info"]):
                                try: procs.append((p.info["name"] or "proc", p.info["pid"], p.info["memory_info"].rss))
                                except Exception: pass
                            procs.sort(key=lambda x:x[2], reverse=True); killed=[]
                            for name,pid,rss in procs:
                                if len(killed)>=kill_top: break
                                if name in exclude: continue
                                try:
                                    os.kill(pid,15); time.sleep(2); os.kill(pid,9); killed.append(f"{name}({pid})")
                                except Exception: pass
                            if killed: self.notify("⛔ AutoRemediator: kill proses berat: "+", ".join(killed))
                        high_since=time.time()
                else:
                    high_since=None
                time.sleep(5)
            except Exception:
                time.sleep(5)
