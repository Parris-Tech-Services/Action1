#!/usr/bin/env python3
"""DadLAN Command Centre v0.3.0 for Fedora/Linux.

Action1 fleet dashboard using the official Action1 REST API.
No Action1 credentials or access tokens are persisted to disk.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from dataclasses import dataclass
from pathlib import Path
import tkinter as tk
from tkinter import messagebox, simpledialog, ttk

from action1_client import Action1Client, Action1Error, REGIONS
from database import init_db, log_action, get_history
from diagnostics import get_diagnostic

init_db()

APP_VERSION = "v0.3.0"

def config_path() -> Path:
    root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dadlan"
    root.mkdir(parents=True, exist_ok=True)
    return root / "machines.json"

@dataclass
class MachineMeta:
    endpointId: str
    laptopNumber: str = ""
    friendlyName: str = ""
    role: str = "Unknown"
    notes: str = ""
    protected: bool = False

    @classmethod
    def from_dict(cls, value: dict) -> "MachineMeta":
        return cls(
            endpointId=str(value.get("endpointId", "")), laptopNumber=str(value.get("laptopNumber", "")),
            friendlyName=str(value.get("friendlyName", "")), role=str(value.get("role", "Unknown")),
            notes=str(value.get("notes", "")), protected=bool(value.get("protected", False)),
        )

    def to_dict(self) -> dict:
        return self.__dict__.copy()

class DadLANApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"DadLAN Command Centre {APP_VERSION}")
        self.geometry("1500x900")
        self.minsize(1100, 720)
        self.client: Action1Client | None = None
        self.org_id: str | None = None
        self.org_name = "None"
        self.endpoints: list[dict] = []
        self.metadata: dict[str, MachineMeta] = {}
        self.busy = False
        self.current_instance_id = None
        self._load_metadata()
        self._build_ui()
        self._activity("System", "Startup", "Info", "Fedora/Linux dashboard ready.")

    def _load_metadata(self) -> None:
        path = config_path()
        if not path.exists():
            return
        try:
            values = json.loads(path.read_text(encoding="utf-8"))
            self.metadata = {str(v.get("endpointId")): MachineMeta.from_dict(v) for v in values if v.get("endpointId")}
        except Exception:
            self.metadata = {}

    def _save_metadata(self) -> None:
        values = [m.to_dict() for m in sorted(self.metadata.values(), key=lambda x: (x.laptopNumber, x.friendlyName))]
        config_path().write_text(json.dumps(values, indent=2), encoding="utf-8")

    def _meta_for(self, endpoint: dict) -> MachineMeta:
        endpoint_id = str(endpoint.get("id", ""))
        if endpoint_id in self.metadata:
            return self.metadata[endpoint_id]
        name = str(endpoint.get("name", ""))
        match = re.search(r"Laptop\s*#?\s*0?(\d{1,2})", name, flags=re.IGNORECASE)
        number, role, protected = "", "Unknown", False
        if match:
            n = int(match.group(1)); number = f"{n:02d}"
            if n == 1: role, protected = "Controller", True
            elif 2 <= n <= 8: role = "Worker"
            elif 9 <= n <= 10: role = "Legacy Worker"
        meta = MachineMeta(endpointId=endpoint_id, laptopNumber=number, friendlyName=name, role=role, protected=protected)
        self.metadata[endpoint_id] = meta
        self._save_metadata()
        return meta

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1); self.rowconfigure(1, weight=1)
        header = ttk.Frame(self, padding=(12, 8)); header.grid(row=0, column=0, sticky="ew"); header.columnconfigure(0, weight=1)
        ttk.Label(header, text="DadLAN Command Centre", font=("Sans", 18, "bold")).grid(row=0, column=0, sticky="w")
        self.summary_var = tk.StringVar(value="0 ONLINE     0 OFFLINE     0 PROBLEMS")
        ttk.Label(header, textvariable=self.summary_var, font=("Sans", 11, "bold")).grid(row=1, column=0, sticky="w", pady=(6, 0))
        self.status_var = tk.StringVar(value="Action1: Disconnected")
        ttk.Label(header, textvariable=self.status_var, justify="right").grid(row=0, column=1, rowspan=2, sticky="e", padx=12)
        ttk.Button(header, text="Connect", command=self.connect).grid(row=0, column=2, rowspan=2, sticky="nsew", padx=4)
        self.refresh_button = ttk.Button(header, text="Refresh", command=self.refresh, state="disabled"); self.refresh_button.grid(row=0, column=3, rowspan=2, sticky="nsew", padx=4)

        content = ttk.Panedwindow(self, orient="horizontal"); content.grid(row=1, column=0, sticky="nsew")
        left, centre, right = ttk.Frame(content, padding=8, width=220), ttk.Frame(content, padding=8), ttk.Frame(content, padding=8, width=390)
        content.add(left, weight=0); content.add(centre, weight=1); content.add(right, weight=0)
        ttk.Label(left, text="FLEET FILTERS", font=("Sans", 10, "bold")).pack(anchor="w")
        self.search_var = tk.StringVar(); search = ttk.Entry(left, textvariable=self.search_var); search.pack(fill="x", pady=(6,8)); search.bind("<KeyRelease>", lambda _e: self._render_grid())
        self.filter_list = tk.Listbox(left, exportselection=False, height=9); self.filter_list.pack(fill="both", expand=True); self.filter_list.bind("<<ListboxSelect>>", lambda _e: self._render_grid())
        for label in ("All", "Online", "Offline", "Controller", "Workers", "Legacy", "Problems"): self.filter_list.insert("end", label)
        self.filter_list.selection_set(0)
        
        ttk.Button(left, text="View History", command=self.view_history).pack(fill="x", pady=(10, 0))

        columns=("health","num","name","role","status","os","ip","last_seen","agent")
        self.tree=ttk.Treeview(centre,columns=columns,show="headings",selectmode="extended")
        headings={"health":("Health",70),"num":("#",45),"name":("Friendly Name",260),"role":("Role",120),"status":("Status",90),"os":("OS",130),"ip":("IP",120),"last_seen":("Last Seen",145),"agent":("Agent",90)}
        for key,(title,width) in headings.items(): self.tree.heading(key,text=title,command=lambda c=key:self._sort_tree(c,False)); self.tree.column(key,width=width,minwidth=45,stretch=(key=="name"))
        y=ttk.Scrollbar(centre,orient="vertical",command=self.tree.yview); x=ttk.Scrollbar(centre,orient="horizontal",command=self.tree.xview); self.tree.configure(yscrollcommand=y.set,xscrollcommand=x.set)
        centre.rowconfigure(0,weight=1); centre.columnconfigure(0,weight=1); self.tree.grid(row=0,column=0,sticky="nsew"); y.grid(row=0,column=1,sticky="ns"); x.grid(row=1,column=0,sticky="ew")
        self.tree.bind("<<TreeviewSelect>>", lambda _e:self._show_selected_details())

        ttk.Label(right,text="LAPTOP DETAILS",font=("Sans",10,"bold")).pack(anchor="w")
        self.details=tk.Text(right,wrap="word",height=20,state="disabled",relief="flat"); self.details.pack(fill="both",expand=True,pady=(8,6))
        buttons=ttk.Frame(right); buttons.pack(fill="x")
        self.edit_button=ttk.Button(buttons,text="Edit Metadata",command=self.edit_metadata,state="disabled"); self.edit_button.pack(side="left",fill="x",expand=True,padx=(0,4))
        self.diag_button=ttk.Button(buttons,text="Read Diagnostics",command=self.read_diagnostics,state="disabled"); self.diag_button.pack(side="left",fill="x",expand=True,padx=(4,0))
        
        actions=ttk.Frame(right); actions.pack(fill="x", pady=(10, 0))
        self.snapshot_button=ttk.Button(actions,text="Remote Action: System Snapshot",command=lambda: self.run_remote_action("system_snapshot"),state="disabled"); self.snapshot_button.pack(side="left",fill="x",expand=True)

        activity_frame=ttk.Frame(self,padding=(8,4,8,8)); activity_frame.grid(row=2,column=0,sticky="nsew"); ttk.Label(activity_frame,text="DadLAN Activity",font=("Sans",10,"bold")).pack(anchor="w")
        self.activity=ttk.Treeview(activity_frame,columns=("time","laptop","action","status","duration","details"),show="headings",height=7)
        for key,title,width in (("time","Time",80),("laptop","Laptop",120),("action","Action",150),("status","Status",80),("duration","Duration",90),("details","Details",700)): self.activity.heading(key,text=title); self.activity.column(key,width=width,stretch=(key=="details"))
        self.activity.pack(fill="both",expand=True,pady=(4,0))

    def _activity(self,laptop,action,status,details,duration=""):
        self.activity.insert("",0,values=(time.strftime("%H:%M:%S"),laptop,action,status,duration,details))

    def connect(self) -> None:
        dialog=tk.Toplevel(self); dialog.title("Action1 Authentication"); dialog.transient(self); dialog.grab_set(); dialog.resizable(False,False)
        ttk.Label(dialog,text="Region").grid(row=0,column=0,sticky="w",padx=12,pady=(12,2)); region=tk.StringVar(value="Australia"); ttk.Combobox(dialog,textvariable=region,values=list(REGIONS),state="readonly",width=42).grid(row=1,column=0,padx=12,sticky="ew")
        ttk.Label(dialog,text="Client ID").grid(row=2,column=0,sticky="w",padx=12,pady=(10,2)); cid=tk.StringVar(value=os.environ.get("ACTION1_CLIENT_ID","")); ttk.Entry(dialog,textvariable=cid,width=48).grid(row=3,column=0,padx=12,sticky="ew")
        ttk.Label(dialog,text="Client Secret").grid(row=4,column=0,sticky="w",padx=12,pady=(10,2)); secret=tk.StringVar(); secret_entry=ttk.Entry(dialog,textvariable=secret,show="•",width=48); secret_entry.grid(row=5,column=0,padx=12,sticky="ew")
        result={}
        def submit():
            if not cid.get().strip() or not secret.get(): messagebox.showwarning("DadLAN","Client ID and Client Secret are required.",parent=dialog); return
            result.update(region=region.get(),client_id=cid.get().strip(),client_secret=secret.get()); secret.set(""); dialog.destroy()
        ttk.Button(dialog,text="Connect",command=submit).grid(row=6,column=0,sticky="e",padx=12,pady=12); dialog.bind("<Return>",lambda _e:submit()); secret_entry.focus_set(); self.wait_window(dialog)
        if not result:return
        self._set_busy(True)
        def worker():
            started=time.monotonic()
            try:
                client=Action1Client(result["region"],result["client_id"],result["client_secret"]); client.authenticate(); orgs=client.organizations(); self.after(0,lambda:self._finish_connection(client,orgs,result["region"],started))
            except Exception as exc:self.after(0,lambda:self._connection_failed(exc,started))
        threading.Thread(target=worker,daemon=True).start()

    def _finish_connection(self,client,orgs,region,started):
        self._set_busy(False)
        if not orgs:self._connection_failed(Action1Error("No organizations returned."),started);return
        org=orgs[0]
        if len(orgs)>1:
            names=[str(o.get("name",o.get("id","Unknown"))) for o in orgs]; choice=simpledialog.askstring("Choose Action1 organization","Multiple organizations found. Enter one exactly:\n\n"+"\n".join(names),parent=self)
            if not choice:return
            matches=[o for o in orgs if str(o.get("name",""))==choice]
            if not matches:messagebox.showerror("DadLAN","Organization name did not match.");return
            org=matches[0]
        self.client=client; self.org_id=str(org.get("id","")); self.org_name=str(org.get("name",self.org_id)); self.refresh_button.configure(state="normal")
        self._activity("System","Authentication","Success",f"Connected to {self.org_name} ({region}).",f"{int((time.monotonic()-started)*1000)} ms"); self.refresh()

    def _connection_failed(self,exc,started):
        self._set_busy(False); self._activity("System","Authentication","Error",str(exc),f"{int((time.monotonic()-started)*1000)} ms"); messagebox.showerror("Action1 connection failed",str(exc),parent=self)

    def refresh(self):
        if not self.client or not self.org_id or self.busy:return
        self._set_busy(True); started=time.monotonic()
        def worker():
            try:self.after(0,lambda:self._finish_refresh(self.client.endpoints(self.org_id),started))
            except Exception as exc:self.after(0,lambda:self._refresh_failed(exc,started))
        threading.Thread(target=worker,daemon=True).start()

    def _finish_refresh(self,endpoints,started):
        self._set_busy(False)
        
        # Inject Fedora and JParrisDesktop manually as first-class nodes
        import socket
        try: f_ip = socket.gethostbyname(socket.gethostname())
        except Exception: f_ip = "127.0.0.1"
        fedora_ep = {"id": "fedora-control-plane", "name": "Fedora (AVANCE-WS7)", "status": "Connected", "OS": "Fedora Linux", "address": f_ip, "last_seen": time.strftime("%Y-%m-%d %H:%M:%S"), "agent_version": "Local"}
        
        try:
            j_ip = socket.gethostbyname("JParrisDesktop")
            j_status = "Connected"
        except Exception:
            j_ip = "UNKNOWN"
            j_status = "Offline"
        jp_ep = {"id": "jparris-desktop", "name": "JParrisDesktop", "status": j_status, "OS": "Windows", "address": j_ip, "last_seen": "Unknown", "agent_version": "N/A"}
        
        endpoints.extend([fedora_ep, jp_ep])
        self.endpoints = endpoints
        
        for endpoint in self.endpoints:
            meta = self._meta_for(endpoint)
            if str(endpoint.get("id")) == "fedora-control-plane":
                meta.laptopNumber = "CP"
                meta.role = "Control Plane"
                meta.protected = True
                if not meta.friendlyName or meta.friendlyName == "Fedora (AVANCE-WS7)": meta.friendlyName = "Fedora Control Plane"
            elif str(endpoint.get("id")) == "jparris-desktop":
                meta.laptopNumber = "DT"
                meta.role = "Desktop"
                meta.protected = True
                if not meta.friendlyName or meta.friendlyName == "JParrisDesktop": meta.friendlyName = "JParris Desktop"

        self._save_metadata(); self._activity("System","Refresh Inventory","Success",f"Fetched {len(endpoints)} endpoints.",f"{int((time.monotonic()-started)*1000)} ms"); self._render_grid(); self.status_var.set(f"Action1: Connected\nOrganisation: {self.org_name} | Refreshed: {time.strftime('%H:%M:%S')}")

    def _refresh_failed(self,exc,started):
        self._set_busy(False); self._activity("System","Refresh Inventory","Error",str(exc),f"{int((time.monotonic()-started)*1000)} ms"); messagebox.showerror("Action1 refresh failed",str(exc),parent=self)

    def _set_busy(self,value):self.busy=value;self.configure(cursor="watch" if value else "")
    def _health(self,endpoint):return "Healthy" if str(endpoint.get("status",""))=="Connected" else "Offline"
    def _active_filter(self):
        selection=self.filter_list.curselection(); return "All" if not selection else self.filter_list.get(selection[0]).split(" (")[0]

    def _render_grid(self):
        selected_filter=self._active_filter(); search=self.search_var.get().casefold().strip(); counts={"All":0,"Online":0,"Offline":0,"Controller":0,"Workers":0,"Legacy":0,"Problems":0}; visible=[]
        for endpoint in self.endpoints:
            meta=self._meta_for(endpoint); health=self._health(endpoint); counts["All"]+=1; counts["Online" if endpoint.get("status")=="Connected" else "Offline"]+=1
            if meta.role=="Controller":counts["Controller"]+=1
            elif meta.role=="Worker":counts["Workers"]+=1
            elif meta.role=="Legacy Worker":counts["Legacy"]+=1
            if health!="Healthy":counts["Problems"]+=1
            if selected_filter=="Online" and endpoint.get("status")!="Connected":continue
            if selected_filter=="Offline" and endpoint.get("status")=="Connected":continue
            if selected_filter=="Controller" and meta.role!="Controller":continue
            if selected_filter=="Workers" and meta.role!="Worker":continue
            if selected_filter=="Legacy" and meta.role!="Legacy Worker":continue
            if selected_filter=="Problems" and health=="Healthy":continue
            if search:
                haystack=" ".join(str(v) for v in (meta.laptopNumber,meta.friendlyName,meta.role,endpoint.get("name",""),endpoint.get("address",""),endpoint.get("OS",""))).casefold()
                if search not in haystack:continue
            visible.append((endpoint,meta,health))
        for item in self.tree.get_children():self.tree.delete(item)
        for endpoint,meta,health in sorted(visible,key=lambda row:(row[1].laptopNumber or "99",row[1].friendlyName)):
            self.tree.insert("","end",iid=str(endpoint.get("id")),values=("OK" if health=="Healthy" else "OFF",meta.laptopNumber,meta.friendlyName,meta.role+(" [Protected]" if meta.protected else ""),endpoint.get("status",""),endpoint.get("OS",""),endpoint.get("address",""),endpoint.get("last_seen",""),endpoint.get("agent_version","")))
        idx=self.filter_list.curselection()[0] if self.filter_list.curselection() else 0; self.filter_list.delete(0,"end")
        for label in ("All","Online","Offline","Controller","Workers","Legacy","Problems"):self.filter_list.insert("end",f"{label} ({counts[label]})")
        self.filter_list.selection_set(min(idx,6)); self.summary_var.set(f"{counts['Online']} ONLINE     {counts['Offline']} OFFLINE     {counts['Problems']} PROBLEMS"); self._show_selected_details()

    def _sort_tree(self,column,reverse):
        data=[(self.tree.set(item,column),item) for item in self.tree.get_children("")]; data.sort(key=lambda p:p[0].casefold(),reverse=reverse)
        for index,(_,item) in enumerate(data):self.tree.move(item,"",index)
        self.tree.heading(column,command=lambda:self._sort_tree(column,not reverse))

    def _selected_endpoint(self):
        selection=self.tree.selection();
        if len(selection)!=1:return None
        return next((e for e in self.endpoints if str(e.get("id"))==selection[0]),None)

    def _show_selected_details(self):
        endpoint=self._selected_endpoint(); self.details.configure(state="normal"); self.details.delete("1.0","end")
        if not endpoint:
            self.details.insert("end",f"{len(self.tree.selection())} endpoints selected." if len(self.tree.selection())>1 else "Select an endpoint to view details."); self.edit_button.configure(state="disabled"); self.diag_button.configure(state="disabled"); self.snapshot_button.configure(state="disabled"); self.details.configure(state="disabled"); return
        meta=self._meta_for(endpoint); health=self._health(endpoint); lines=[f"Laptop #{meta.laptopNumber}",meta.friendlyName,"",("PROTECTED CONTROLLER" if meta.protected else ""),"",f"Health: {health}",f"Role: {meta.role}",f"Status: {endpoint.get('status','')}",f"OS: {endpoint.get('OS','')}",f"IP: {endpoint.get('address','')}",f"Last Seen: {endpoint.get('last_seen','')}",f"Agent: {endpoint.get('agent_version','')}","",f"Endpoint Name:\n{endpoint.get('name','')}","",f"Endpoint ID:\n{endpoint.get('id','')}","",f"Notes:\n{meta.notes}"]
        self.details.insert("end","\n".join(lines)); self.details.configure(state="disabled"); self.edit_button.configure(state="normal"); self.diag_button.configure(state="normal")
        can_run = (not meta.protected) and (meta.role == "Worker") and (meta.laptopNumber != "01")
        self.snapshot_button.configure(state="normal" if can_run else "disabled")

    def edit_metadata(self):
        endpoint=self._selected_endpoint()
        if not endpoint:return
        meta=self._meta_for(endpoint); dialog=tk.Toplevel(self); dialog.title("Edit Local Metadata"); dialog.transient(self); dialog.grab_set(); dialog.columnconfigure(1,weight=1)
        num=tk.StringVar(value=meta.laptopNumber); name=tk.StringVar(value=meta.friendlyName); role=tk.StringVar(value=meta.role); protected=tk.BooleanVar(value=meta.protected)
        for row,(label,var) in enumerate((("Laptop #",num),("Friendly Name",name))):ttk.Label(dialog,text=label).grid(row=row,column=0,sticky="w",padx=10,pady=6);ttk.Entry(dialog,textvariable=var,width=45).grid(row=row,column=1,sticky="ew",padx=10,pady=6)
        ttk.Label(dialog,text="Role").grid(row=2,column=0,sticky="w",padx=10,pady=6);ttk.Combobox(dialog,textvariable=role,values=("Controller","Worker","Legacy Worker","Unknown"),state="readonly").grid(row=2,column=1,sticky="ew",padx=10,pady=6)
        ttk.Checkbutton(dialog,text="Protected (exclude from future fleet actions)",variable=protected).grid(row=3,column=1,sticky="w",padx=10,pady=6)
        notes=tk.Text(dialog,width=45,height=6);notes.insert("1.0",meta.notes);notes.grid(row=4,column=1,sticky="nsew",padx=10,pady=6);ttk.Label(dialog,text="Notes").grid(row=4,column=0,sticky="nw",padx=10,pady=6)
        def save():
            meta.laptopNumber=num.get().strip();meta.friendlyName=name.get().strip();meta.role=role.get();meta.protected=protected.get();meta.notes=notes.get("1.0","end-1c");self._save_metadata();self._activity(meta.laptopNumber or "Endpoint","Edit Metadata","Success","Updated local metadata only.");dialog.destroy();self._render_grid()
        ttk.Button(dialog,text="Save",command=save).grid(row=5,column=1,sticky="e",padx=10,pady=10)

    def read_diagnostics(self):
        endpoint=self._selected_endpoint()
        if not endpoint or not self.client or not self.org_id or self.busy:return
        endpoint_id=str(endpoint.get("id"));endpoint_name=str(endpoint.get("name",endpoint_id));self._set_busy(True);started=time.monotonic()
        def worker():
            try:self.after(0,lambda:self._finish_diagnostics(endpoint_name,self.client.endpoint(self.org_id,endpoint_id),started))
            except Exception as exc:self.after(0,lambda:self._diagnostics_failed(endpoint_name,exc,started))
        threading.Thread(target=worker,daemon=True).start()

    def _finish_diagnostics(self,endpoint_name,diag,started):
        self._set_busy(False);self._activity(endpoint_name,"Read Diagnostics","Success","Read-only endpoint details retrieved.",f"{int((time.monotonic()-started)*1000)} ms");self.details.configure(state="normal");self.details.insert("end","\n\nRAW DIAGNOSTICS\n------------------------------\n")
        for key in sorted(diag):self.details.insert("end",f"{key}: {diag[key]}\n")
        self.details.configure(state="disabled")

    def _diagnostics_failed(self,endpoint_name,exc,started):
        self._set_busy(False);self._activity(endpoint_name,"Read Diagnostics","Error",str(exc),f"{int((time.monotonic()-started)*1000)} ms");messagebox.showerror("Diagnostics failed",str(exc),parent=self)

    def run_remote_action(self, diag_id: str):
        endpoint=self._selected_endpoint()
        if not endpoint or not self.client or not self.org_id or self.busy:return
        
        meta=self._meta_for(endpoint)
        if meta.protected or meta.role != "Worker" or meta.laptopNumber == "01":
            messagebox.showwarning("DadLAN", "Cannot run actions on protected machines, controllers, or non-workers.", parent=self)
            return

        try:
            diag = get_diagnostic(diag_id)
        except ValueError as e:
            messagebox.showerror("DadLAN", str(e), parent=self)
            return

        endpoint_id=str(endpoint.get("id"))
        endpoint_name=str(endpoint.get("name",endpoint_id))

        msg = f"Execute Remote Action on {endpoint_name}?\n\n"
        msg += f"Target: {endpoint_name} (ID: {endpoint_id[:8]}...)\n"
        msg += f"Role: {meta.role}\n"
        msg += f"Action: {diag['name']}\n"
        msg += f"Description: {diag['description']}\n\n"
        msg += "This will create a one-shot Action1 automation."

        if not messagebox.askyesno("DadLAN", msg, parent=self):
            return

        self._set_busy(True);started=time.monotonic()
        
        self.snapshot_button.configure(text="Submitting...", state="disabled", command=lambda: self.cancel_action(endpoint_name, started))
        self.current_instance_id = None
        
        self._activity(endpoint_name, diag['name'], "Queued", f"Requesting execution of {diag['name']}...")

        def worker():
            try:
                res = self.client.run_script(self.org_id, endpoint_id, diag['script'], name=f"DadLAN: {diag['name']}")
                instance_id = str(res.get("id", ""))
                self.current_instance_id = instance_id
                self.after(0, lambda: self.snapshot_button.configure(text="Cancel Action", state="normal"))
                self.after(0, lambda: self._poll_action_result(endpoint_name, endpoint_id, instance_id, diag, started))
            except Exception as exc:
                self.after(0,lambda:self._action_failed(endpoint_name, diag['name'], exc, started))
        threading.Thread(target=worker,daemon=True).start()

    def cancel_action(self, endpoint_name, started):
        if not self.current_instance_id: return
        self.snapshot_button.configure(state="disabled", text="Cancelling...")
        self._activity(endpoint_name, "Cancel", "Running", f"Stopping instance {self.current_instance_id}...")
        def worker():
            try:
                self.client.stop_automation(self.org_id, self.current_instance_id)
            except Exception: pass
        threading.Thread(target=worker, daemon=True).start()

    def _poll_action_result(self, endpoint_name, endpoint_id, instance_id, diag, started):
        if not instance_id:
            self._action_failed(endpoint_name, diag['name'], Exception("No instance ID returned by Action1."), started)
            return
        
        self._activity(endpoint_name, diag['name'], "Running", f"Created instance {instance_id}. Polling for results...")
        
        def worker():
            max_attempts = 24 # 2 minutes max
            for _ in range(max_attempts):
                try:
                    results = self.client.automation_endpoint_results(self.org_id, instance_id)
                    ep_res = next((r for r in results if str(r.get("endpoint_id")) == endpoint_id), None)
                    if ep_res:
                        status = str(ep_res.get("status", ""))
                        if status.lower() in ("success", "warning", "error", "stopped"):
                            details = self.client.automation_endpoint_details(self.org_id, instance_id, endpoint_id)
                            self.after(0, lambda d=details, s=status: self._action_completed(endpoint_name, instance_id, s, d, diag, started))
                            return
                except Exception:
                    pass
                time.sleep(5)
            self.after(0, lambda: self._action_failed(endpoint_name, diag['name'], Exception("Polling timeout reached."), started))
            try: self.client.stop_automation(self.org_id, instance_id)
            except: pass
        threading.Thread(target=worker,daemon=True).start()

    def _action_completed(self, endpoint_name, instance_id, status, details, diag, started):
        self._set_busy(False)
        self.snapshot_button.configure(text="Remote Action: System Snapshot", command=lambda: self.run_remote_action("system_snapshot"))
        duration = f"{int((time.monotonic()-started)*1000)} ms"
        
        raw_output = details.get("output", details.get("result", ""))
        try:
            parsed = json.loads(raw_output)
            output = json.dumps(parsed, indent=2)
        except Exception:
            output = raw_output

        self._activity(endpoint_name, diag['name'], status.capitalize(), f"Instance: {instance_id}", duration)
        log_action(endpoint_name, diag['name'], instance_id, status, duration, output)
        
        self.details.configure(state="normal")
        self.details.insert("end", f"\n\n--- {diag['name'].upper()} RESULTS ---\n{output}\n")
        self.details.configure(state="disabled")

    def _action_failed(self, endpoint_name, action_name, exc, started):
        self._set_busy(False)
        self.snapshot_button.configure(text="Remote Action: System Snapshot", command=lambda: self.run_remote_action("system_snapshot"))
        duration = f"{int((time.monotonic()-started)*1000)} ms"
        self._activity(endpoint_name, action_name, "Failed", str(exc), duration)
        log_action(endpoint_name, action_name, "", "Error", duration, str(exc))
        messagebox.showerror("Action failed", str(exc), parent=self)

    def view_history(self):
        dialog = tk.Toplevel(self); dialog.title("Job History"); dialog.transient(self); dialog.grab_set()
        dialog.geometry("800x400")
        
        columns = ("timestamp", "target", "action", "status", "duration")
        tree = ttk.Treeview(dialog, columns=columns, show="headings")
        headings = {"timestamp": ("Time", 140), "target": ("Target", 150), "action": ("Action", 150), "status": ("Status", 80), "duration": ("Duration", 100)}
        for key, (title, width) in headings.items(): tree.heading(key, text=title); tree.column(key, width=width)
        
        y = ttk.Scrollbar(dialog, orient="vertical", command=tree.yview); tree.configure(yscrollcommand=y.set)
        tree.pack(side="left", fill="both", expand=True); y.pack(side="right", fill="y")
        
        for row in get_history():
            tree.insert("", "end", values=(row["timestamp"], row["target"], row["action"], row["status"], row["duration"]))

if __name__ == "__main__":
    DadLANApp().mainloop()
